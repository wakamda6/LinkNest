import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'file_record.dart';
import 'app_identity.dart';
import 'protocol.dart';
import 'space_data_source.dart';
import 'space_invite.dart';

typedef GuestUploadProgressCallback = void Function(
  int completedBytes,
  int totalBytes,
);

typedef GuestDownloadProgressCallback = void Function(
  int completedBytes,
  int totalBytes,
);

class SpaceHandshake {
  const SpaceHandshake({
    required this.spaceId,
    required this.sessionId,
    required this.spaceName,
    required this.spaceUpdatedAt,
    required this.visitorName,
    this.uploaderId = '',
    required this.protocolVersion,
    required this.hostVersion,
    required this.capabilities,
  });

  final String spaceId;
  final String sessionId;
  final String spaceName;
  final DateTime spaceUpdatedAt;
  final String visitorName;
  final String uploaderId;
  final int protocolVersion;
  final String hostVersion;
  final Set<String> capabilities;
}

class GuestApiException implements Exception {
  const GuestApiException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class GuestApiClient {
  GuestApiClient({
    required this.invite,
    http.Client? client,
    String? installationId,
    this.requestTimeout = const Duration(seconds: 5),
    this.uploadTimeout = const Duration(hours: 6),
  }) : installationId = installationId ?? AppIdentity.id,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const int _maximumMetaBytes = 64 * 1024;
  static const int _maximumListBytes = 16 * 1024 * 1024;
  static const int _maximumThumbnailBytes = 8 * 1024 * 1024;
  static const int _maximumPreviewBytes = 32 * 1024 * 1024;
  static const Duration _thumbnailTimeout = Duration(seconds: 15);
  static const Duration _previewTimeout = Duration(seconds: 20);
  static const Duration _downloadIdleTimeout = Duration(seconds: 30);
  static final RegExp _validFileId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final SpaceInvite invite;
  final String installationId;
  final Duration requestTimeout;
  final Duration uploadTimeout;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  Future<SpaceHandshake> handshake() async {
    final response = await _get(
      'api/meta',
      maximumBytes: _maximumMetaBytes,
      timeout: requestTimeout,
    );
    final envelope = _decodeEnvelope(response.body);
    if (envelope['ok'] != true || envelope['data'] is! Map) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的数据格式不正确。');
    }

    final data = Map<String, dynamic>.from(envelope['data'] as Map);
    final protocolVersion = data['protocolVersion'];
    if (protocolVersion is! int) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 未返回有效的协议版本。');
    }
    if (protocolVersion != linkNestProtocolVersion) {
      throw GuestApiException(
        'INCOMPATIBLE_PROTOCOL',
        'Host 协议版本为 $protocolVersion，当前 App 仅支持版本 '
            '$linkNestProtocolVersion。请升级 App 或改用 Web 备用入口。',
      );
    }

    final rawCapabilities = data['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.any((value) => value is! String)) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 未返回有效的能力列表。');
    }
    final capabilities = rawCapabilities.cast<String>().toSet();
    final missing = guestRequiredCapabilities
        .where((capability) => !capabilities.contains(capability))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      throw GuestApiException(
        'MISSING_CAPABILITY',
        'Host 缺少当前 App 所需能力（${missing.join('、')}）。请升级 Host '
            '或改用 Web 备用入口。',
      );
    }

    final spaceId = data['spaceId'];
    final sessionId = data['sessionId'];
    final spaceName = data['spaceName'];
    final spaceUpdatedAt = data['spaceUpdatedAt'];
    final visitorName = data['visitorName'];
    final hostVersion = data['hostVersion'];
    if (spaceId is! String ||
        spaceId.isEmpty ||
        sessionId is! String ||
        sessionId.isEmpty ||
        spaceName is! String ||
        spaceUpdatedAt is! int ||
        visitorName is! String ||
        hostVersion is! String) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的空间信息不完整。');
    }

    return SpaceHandshake(
      spaceId: spaceId,
      sessionId: sessionId,
      spaceName: spaceName,
      spaceUpdatedAt: DateTime.fromMillisecondsSinceEpoch(
        spaceUpdatedAt,
        isUtc: true,
      ),
      visitorName: visitorName,
      uploaderId: data['uploaderId'] is String
          ? data['uploaderId'] as String
          : '',
      protocolVersion: protocolVersion,
      hostVersion: hostVersion,
      capabilities: Set.unmodifiable(capabilities),
    );
  }

  Future<List<FileRecord>> listFiles() async {
    final response = await _get(
      'api/files',
      maximumBytes: _maximumListBytes,
      timeout: requestTimeout,
    );
    final envelope = _decodeEnvelope(response.body);
    final data = envelope['data'];
    if (envelope['ok'] != true || data is! List) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的文件列表格式不正确。');
    }

    return List<FileRecord>.unmodifiable(data.map(_decodeFileRecord));
  }

  Future<Uint8List> thumbnail(String id) => _loadJpeg(
    id,
    resource: 'thumbnail',
    maximumBytes: _maximumThumbnailBytes,
    timeout: _thumbnailTimeout,
  );

  Future<Uint8List> preview(String id) => _loadJpeg(
    id,
    resource: 'preview',
    maximumBytes: _maximumPreviewBytes,
    timeout: _previewTimeout,
  );

  NetworkVideoPlaybackSource videoPlaybackSource(FileRecord record) {
    _ensureOpen();
    if (!_validFileId.hasMatch(record.id) || record.kind != 'video') {
      throw const GuestApiException('INVALID_VIDEO', '视频记录无效。');
    }
    return NetworkVideoPlaybackSource(
      uri: invite.baseUri.resolve('api/files/${record.id}/download'),
      headers: Map.unmodifiable({
        HttpHeaders.authorizationHeader: 'Bearer ${invite.token}',
        HttpHeaders.acceptHeader: record.mimeType,
      }),
    );
  }

  Future<List<FileRecord>> uploadFile(
    File file, {
    required String name,
    required String uploader,
    GuestUploadProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    cancellation?.throwIfCancelled();
    if (!await file.exists()) {
      throw const GuestApiException(
        'UPLOAD_FILE_MISSING',
        '待上传文件不存在，请重新从相册选择。',
      );
    }
    final length = await file.length();
    final request =
        http.AbortableMultipartRequest(
            'POST',
            invite.baseUri.resolve('api/upload'),
            abortTrigger: cancellation?.whenCancelled,
          )
          ..followRedirects = false
          ..headers.addAll({
            if (installationId.isNotEmpty) AppIdentity.header: installationId,
          })
          ..headers['Authorization'] = 'Bearer ${invite.token}'
          ..headers['Accept'] = 'application/json'
          ..fields['uploader'] = uploader;
    var completed = 0;
    final stream = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          completed += chunk.length;
          onProgress?.call(completed, length);
          sink.add(chunk);
        },
      ),
    );
    request.files.add(
      http.MultipartFile(
        'file',
        stream,
        length,
        filename: name.trim().isEmpty ? '未知文件' : name,
      ),
    );

    final response = await _sendRequest(
      request,
      logPath: '/api/upload',
      maximumBytes: _maximumListBytes,
      timeout: uploadTimeout,
    );
    final envelope = _decodeEnvelope(response.body);
    final data = envelope['data'];
    if (envelope['ok'] != true || data is! List || data.length > 1) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的上传结果格式不正确。');
    }
    return List<FileRecord>.unmodifiable(data.map(_decodeFileRecord));
  }

  Future<List<FileRecord>> uploadLivePhoto(
    File photo,
    File pairedVideo, {
    required String photoName,
    required String pairedVideoName,
    required String uploader,
    GuestUploadProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    cancellation?.throwIfCancelled();
    if (!await photo.exists() || !await pairedVideo.exists()) {
      throw const GuestApiException(
        'UPLOAD_FILE_MISSING',
        'Live Photo 组成资源不存在，请重新从相册选择。',
      );
    }
    final photoLength = await photo.length();
    final videoLength = await pairedVideo.length();
    final total = photoLength + videoLength;
    var photoCompleted = 0;
    var videoCompleted = 0;
    Stream<List<int>> progressStream(
      File file,
      void Function(int value) update,
    ) => file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          update(chunk.length);
          onProgress?.call(photoCompleted + videoCompleted, total);
          sink.add(chunk);
        },
      ),
    );
    final request =
        http.AbortableMultipartRequest(
            'POST',
            invite.baseUri.resolve('api/upload'),
            abortTrigger: cancellation?.whenCancelled,
          )
          ..followRedirects = false
          ..headers.addAll({
            if (installationId.isNotEmpty) AppIdentity.header: installationId,
          })
          ..headers['Authorization'] = 'Bearer ${invite.token}'
          ..headers['Accept'] = 'application/json'
          ..fields['uploader'] = uploader;
    request.files.addAll([
      http.MultipartFile(
        'photo',
        progressStream(photo, (value) => photoCompleted += value),
        photoLength,
        filename: photoName,
      ),
      http.MultipartFile(
        'pairedVideo',
        progressStream(pairedVideo, (value) => videoCompleted += value),
        videoLength,
        filename: pairedVideoName,
      ),
    ]);
    final response = await _sendRequest(
      request,
      logPath: '/api/upload (Live Photo)',
      maximumBytes: _maximumListBytes,
      timeout: uploadTimeout,
    );
    final envelope = _decodeEnvelope(response.body);
    final data = envelope['data'];
    if (envelope['ok'] != true || data is! List || data.length > 1) {
      throw const GuestApiException(
        'INVALID_RESPONSE',
        'Host 返回的 Live Photo 上传结果格式不正确。',
      );
    }
    return List<FileRecord>.unmodifiable(data.map(_decodeFileRecord));
  }

  Future<void> downloadFile(
    FileRecord record,
    File destination, {
    MediaResource? resource,
    GuestDownloadProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    cancellation?.throwIfCancelled();
    if (!_validFileId.hasMatch(record.id)) {
      throw const GuestApiException('INVALID_FILE_ID', '文件标识无效。');
    }
    final partial = File('${destination.path}.part');
    RandomAccessFile? writer;
    ByteConversionSink? hashInput;
    var delivered = false;
    try {
      await destination.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      if (await destination.exists()) await destination.delete();

      final selected = resource ?? record.primaryResource;
      final isPairedVideo =
          record.isLivePhoto && identical(selected, record.pairedVideo);
      final downloadUri = invite.baseUri
          .resolve('api/files/${record.id}/download')
          .replace(
            queryParameters: isPairedVideo
                ? const {'resource': 'pairedVideo'}
                : null,
          );
      final request =
          http.AbortableRequest(
              'GET',
              downloadUri,
              abortTrigger: cancellation?.whenCancelled,
            )
            ..followRedirects = false
            ..headers.addAll({
              if (installationId.isNotEmpty) AppIdentity.header: installationId,
            })
            ..headers['Authorization'] = 'Bearer ${invite.token}'
            ..headers['Accept'] = selected.mimeType;
      if (kDebugMode) {
        debugPrint(
          '[LinkNest] 访客请求原文件下载接口 method=GET path=/api/files/:id/download',
        );
      }
      final response = await _client.send(request).timeout(requestTimeout);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await _cancelResponse(response);
        throw const GuestApiException(
          'UNEXPECTED_REDIRECT',
          'Host 返回了意外跳转，请重新扫描空间码。',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await _readBody(
          response,
          maximumBytes: _maximumMetaBytes,
        ).timeout(requestTimeout);
        throw _serverException(response.statusCode, body);
      }

      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength != selected.size) {
        await _cancelResponse(response);
        throw const GuestApiException(
          'DOWNLOAD_LENGTH_MISMATCH',
          'Host 返回的原文件大小与列表记录不一致。',
        );
      }
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType != selected.mimeType.toLowerCase()) {
        await _cancelResponse(response);
        throw const GuestApiException(
          'DOWNLOAD_MIME_MISMATCH',
          'Host 返回的原文件类型与列表记录不一致。',
        );
      }

      writer = await partial.open(mode: FileMode.write);
      Digest? digest;
      hashInput = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((values) {
          digest = values.single;
        }),
      );
      var completed = 0;
      await for (final chunk in response.stream.timeout(_downloadIdleTimeout)) {
        _ensureOpen();
        cancellation?.throwIfCancelled();
        completed += chunk.length;
        if (completed > selected.size) {
          throw const GuestApiException(
            'DOWNLOAD_LENGTH_MISMATCH',
            'Host 返回的原文件大小与列表记录不一致。',
          );
        }
        await writer.writeFrom(chunk);
        hashInput.add(chunk);
        onProgress?.call(completed, selected.size);
      }
      await writer.flush();
      await writer.close();
      writer = null;
      hashInput.close();
      hashInput = null;
      if (completed != selected.size) {
        throw const GuestApiException(
          'DOWNLOAD_LENGTH_MISMATCH',
          '原文件下载不完整，请重试。',
        );
      }
      if (selected.sha256.isNotEmpty && digest.toString() != selected.sha256) {
        throw const GuestApiException(
          'DOWNLOAD_HASH_MISMATCH',
          '原文件完整性校验失败，请重试。',
        );
      }
      _ensureOpen();
      await partial.rename(destination.path);
      delivered = true;
      if (kDebugMode) {
        debugPrint(
          '[LinkNest] 访客原文件下载接口返回 method=GET path=/api/files/:id/download '
          'status=${response.statusCode} bytes=$completed',
        );
      }
    } on GuestApiException {
      rethrow;
    } on SpaceTransferCancelledException {
      rethrow;
    } on http.RequestAbortedException {
      throw const SpaceTransferCancelledException();
    } on TimeoutException {
      throw const GuestApiException('DOWNLOAD_TIMEOUT', '原文件下载超时，请检查热点连接后重试。');
    } on http.ClientException {
      throw const GuestApiException('CONNECTION_FAILED', '原文件下载中断，请检查热点连接后重试。');
    } on FileSystemException {
      throw const GuestApiException(
        'DOWNLOAD_WRITE_FAILED',
        '无法写入下载临时文件，请检查设备存储空间。',
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[LinkNest] 访客原文件下载失败 reason=${error.runtimeType}');
      }
      throw const GuestApiException('DOWNLOAD_FAILED', '原文件下载失败，请稍后重试。');
    } finally {
      if (writer != null) {
        try {
          await writer.close();
        } on Object {
          // 后续统一清理未完成文件。
        }
      }
      if (hashInput != null) {
        try {
          hashInput.close();
        } on Object {
          // 哈希状态无需在失败后保留。
        }
      }
      if (!delivered) {
        for (final file in [partial, destination]) {
          try {
            if (await file.exists()) await file.delete();
          } on Object {
            // 原错误优先；缓存目录还会由操作系统回收。
          }
        }
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  Future<Uint8List> _loadJpeg(
    String id, {
    required String resource,
    required int maximumBytes,
    required Duration timeout,
  }) async {
    if (!_validFileId.hasMatch(id)) {
      throw const GuestApiException('INVALID_FILE_ID', '文件标识无效。');
    }
    final response = await _get(
      'api/files/$id/$resource',
      maximumBytes: maximumBytes,
      timeout: timeout,
    );
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final bytes = response.bytes;
    if (contentType.split(';').first.trim() != 'image/jpeg' ||
        bytes.length < 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw const GuestApiException('INVALID_PREVIEW', 'Host 返回的预览数据无效。');
    }
    return bytes;
  }

  Future<_BufferedResponse> _get(
    String path, {
    required int maximumBytes,
    required Duration timeout,
  }) async {
    final request = http.Request('GET', invite.baseUri.resolve(path))
      ..followRedirects = false
      ..headers.addAll({
        if (installationId.isNotEmpty) AppIdentity.header: installationId,
      })
      ..headers['Authorization'] = 'Bearer ${invite.token}'
      ..headers['Accept'] = 'application/json, image/jpeg';

    return _sendRequest(
      request,
      logPath: '/$path',
      maximumBytes: maximumBytes,
      timeout: timeout,
    );
  }

  Future<_BufferedResponse> _sendRequest(
    http.BaseRequest request, {
    required String logPath,
    required int maximumBytes,
    required Duration timeout,
  }) async {
    _ensureOpen();

    if (kDebugMode) {
      debugPrint(
        '[LinkNest] 访客发起 HTTP 请求 method=${request.method} path=$logPath',
      );
    }

    try {
      final response = await _client.send(request).timeout(timeout);
      final bytes = await _readBody(
        response,
        maximumBytes: maximumBytes,
      ).timeout(timeout);

      if (kDebugMode) {
        debugPrint(
          '[LinkNest] 访客 HTTP 请求完成 method=${request.method} path=$logPath '
          'status=${response.statusCode} '
          'bytes=${bytes.length}',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const GuestApiException(
          'UNEXPECTED_REDIRECT',
          'Host 返回了意外跳转，请重新扫描空间码。',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _serverException(response.statusCode, bytes);
      }
      return _BufferedResponse(
        bytes,
        Map<String, String>.unmodifiable(response.headers),
      );
    } on GuestApiException {
      rethrow;
    } on SpaceTransferCancelledException {
      rethrow;
    } on http.RequestAbortedException {
      throw const SpaceTransferCancelledException();
    } on TimeoutException {
      throw const GuestApiException(
        'CONNECTION_TIMEOUT',
        '连接 Host 超时。请确认已加入发起者热点后重试。',
      );
    } on http.ClientException {
      throw const GuestApiException(
        'CONNECTION_FAILED',
        '无法连接 Host。请确认已加入发起者热点，并检查空间地址后重试。',
      );
    } on FormatException {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的数据无法解析。');
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[LinkNest] 访客 HTTP 请求失败 method=${request.method} path=$logPath reason='
          '${error.runtimeType}',
        );
      }
      throw const GuestApiException('CONNECTION_FAILED', '连接 Host 失败，请稍后重试。');
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const GuestApiException('CLIENT_CLOSED', '访客连接已关闭。');
    }
  }

  static Future<Uint8List> _readBody(
    http.StreamedResponse response, {
    required int maximumBytes,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const GuestApiException('RESPONSE_TOO_LARGE', 'Host 返回的数据过大。');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<void> _cancelResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen((_) {});
    await subscription.cancel();
  }

  static Map<String, dynamic> _decodeEnvelope(Uint8List body) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的数据无法解析。');
    }
    if (decoded is! Map) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的数据格式不正确。');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static FileRecord _decodeFileRecord(Object? value) {
    if (value is! Map) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的文件记录格式不正确。');
    }
    final json = Map<String, dynamic>.from(value);
    final id = json['id'];
    final name = json['name'];
    final size = json['size'];
    final kind = json['kind'];
    final mimeType = json['mimeType'];
    final previewStatus = json['previewStatus'];
    final uploader = json['uploader'];
    final sha256 = json['sha256'];
    final uploadedAt = json['uploadedAt'];
    if (id is! String ||
        !_validFileId.hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        size is! int ||
        size < 0 ||
        kind is! String ||
        !const {'image', 'video', 'other'}.contains(kind) ||
        mimeType is! String ||
        previewStatus is! String ||
        !PreviewStatus.isValid(previewStatus) ||
        uploader is! String ||
        sha256 is! String ||
        uploadedAt is! int ||
        uploadedAt < 0) {
      throw const GuestApiException('INVALID_RESPONSE', 'Host 返回的文件记录不完整。');
    }
    final record = FileRecord.fromJson(json);
    final declaresLivePhoto = json['mediaType'] == 'livePhoto';
    if (declaresLivePhoto != record.isLivePhoto ||
        (record.isLivePhoto &&
            (record.photoResource!.name.isEmpty ||
                record.photoResource!.size < 0 ||
                !record.photoResource!.mimeType.startsWith('image/') ||
                record.photoResource!.sha256.isEmpty ||
                record.pairedVideo!.name.isEmpty ||
                record.pairedVideo!.size < 0 ||
                !record.pairedVideo!.mimeType.startsWith('video/') ||
                record.pairedVideo!.sha256.isEmpty ||
                record.size !=
                    record.photoResource!.size + record.pairedVideo!.size))) {
      throw const GuestApiException(
        'INVALID_RESPONSE',
        'Host 返回的 Live Photo 记录不完整。',
      );
    }
    return record;
  }

  static GuestApiException _serverException(int statusCode, Uint8List body) {
    try {
      final envelope = _decodeEnvelope(body);
      final code = envelope['code'];
      final message = envelope['error'];
      if (code is String && message is String) {
        return GuestApiException(code, message, statusCode: statusCode);
      }
      final nestedError = envelope['error'];
      if (nestedError is Map) {
        final nestedCode = nestedError['code'];
        final nestedMessage = nestedError['message'];
        if (nestedCode is String && nestedMessage is String) {
          return GuestApiException(
            nestedCode,
            nestedMessage,
            statusCode: statusCode,
          );
        }
      }
    } on Object {
      // 非 JSON 错误页使用下面的通用提示。
    }
    return GuestApiException(
      'HTTP_$statusCode',
      statusCode == 401
          ? '空间令牌已失效，请重新扫描发起者当前显示的空间码。'
          : 'Host 请求失败（HTTP $statusCode）。',
      statusCode: statusCode,
    );
  }
}

class _BufferedResponse {
  const _BufferedResponse(this.bytes, this.headers);

  final Uint8List bytes;
  final Map<String, String> headers;

  Uint8List get body => bytes;
}
