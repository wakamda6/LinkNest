import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

import 'device_name.dart';
import 'app_identity.dart';
import 'file_record.dart';
import 'index_store.dart';
import 'media_format.dart';
import 'native.dart';
import 'protocol.dart';
import 'settings_state.dart';
import 'space_discovery.dart';
import 'space_invite.dart';
import 'space_repository.dart';
import 'space_state.dart';
import 'upload_policy.dart';

export 'file_record.dart';
export 'protocol.dart' show linkNestCapabilities, linkNestProtocolVersion;

class _PendingFile {
  const _PendingFile({
    required this.file,
    required this.name,
    required this.size,
    required this.sha256,
    required this.format,
  });

  final File file;
  final String name;
  final int size;
  final String sha256;
  final MediaFormat format;
}

class HistorySpaceSnapshot {
  const HistorySpaceSnapshot({
    required this.space,
    required this.files,
    required this.isActive,
  });

  final Space space;
  final List<FileRecord> files;
  final bool isActive;

  int get totalBytes => files.fold(0, (total, file) => total + file.size);
  List<String> get locationLabels => files
      .map((file) => file.photoLocation?.label)
      .whereType<String>()
      .where((label) => label.isNotEmpty)
      .toSet()
      .toList();
}

/// 本地 HTTP 服务及 Host 进程内文件接口。
class LinkNestServer {
  LinkNestServer({
    LinkNestNative? native,
    Directory? rootDirectory,
    String? installationId,
    this.uploadPolicy = const UploadPolicy(),
  }) : _installationId = installationId ?? AppIdentity.id,
       _native = native ?? LinkNestNative(),
       _rootOverride = rootDirectory;

  final LinkNestNative _native;
  final String _installationId;
  final Directory? _rootOverride;
  final UploadPolicy uploadPolicy;
  final AsyncMutex _indexMutex = AsyncMutex();
  final AsyncLimiter _previewLimiter = AsyncLimiter(2);
  final Map<String, AsyncMutex> _previewMutexes = {};
  final List<FileRecord> _files = [];
  final Map<String, DateTime> _activeClients = {};
  final Map<String, String> _clientNames = {};
  final Set<String> _webSessions = {};
  final LinkNestDiscoveryAdvertiser _discoveryAdvertiser =
      LinkNestDiscoveryAdvertiser();
  Timer? _advertisementRetry;
  int _advertisementGeneration = 0;

  HttpServer? _server;
  late Directory _root;
  late Directory _filesDir;
  late Directory _incomingDir;
  late Directory _thumbsDir;
  late Directory _previewsDir;
  late Directory _transactionsDir;
  late Directory _lostFoundDir;
  late Directory _deleteTransactionsDir;
  late Directory _trashDir;
  SpaceRepository? _spaceRepository;
  Space? _activeSpace;
  SharingSession? _activeSession;
  String _hostVersion = 'unknown';
  String _baseUrl = '';
  String? _selectedAddress;
  String? _selectedInterface;
  bool _bindSelectedAddress = false;
  String _spaceToken = '';
  List<String> _baseUrls = const [];
  int _idSequence = 0;
  int _activeUploads = 0;
  bool _storageRecovered = false;
  Future<void>? _locationResolution;

  bool get running => _server != null;
  String get inviteUrl => '$_baseUrl/#token=$_spaceToken';
  List<String> get inviteUrls =>
      List.unmodifiable(_baseUrls.map((url) => '$url/#token=$_spaceToken'));

  int get onlineCount {
    final now = DateTime.now();
    _activeClients.removeWhere(
      (_, last) => now.difference(last).inSeconds > 30,
    );
    return _activeClients.length;
  }

  List<Map<String, dynamic>> get clients => _clients();
  List<FileRecord> get files => List.unmodifiable(_files);
  Space? get activeSpace => _activeSpace;
  String get hostUploaderId => _activeSpace == null
      ? ''
      : AppIdentity.forSpace(_activeSpace!.id, _installationId);
  String filePath(String id) => '${_filesDir.path}/$id';
  String pairedVideoPath(String id) => '${_filesDir.path}/$id.paired';

  Future<Space?> recentSpace({
    Duration maximumAge = const Duration(hours: 72),
    DateTime? now,
  }) async {
    if (maximumAge.isNegative) {
      throw ArgumentError.value(maximumAge, 'maximumAge', 'is negative');
    }
    final repository = await _prepareStorage();
    final latest = repository.latestSpace;
    if (latest == null) return null;
    final age = (now ?? DateTime.now()).toUtc().difference(
      latest.lastActivityAt.toUtc(),
    );
    return age <= maximumAge ? latest : null;
  }

  Future<List<Space>> availableSpaces() async {
    final repository = await _prepareStorage();
    return repository.spacesByRecentActivity;
  }

  Future<List<HistorySpaceSnapshot>> historySpaces() async {
    final repository = await _prepareStorage();
    final activeId = _activeSpace?.id;
    return repository.spacesByRecentActivity
        .map(
          (space) => HistorySpaceSnapshot(
            space: space,
            files: repository.filesForSpace(space.id),
            isActive: space.id == activeId && running,
          ),
        )
        .toList();
  }

  Future<void> resolveHistoryLocations() {
    final existing = _locationResolution;
    if (existing != null) return existing;
    final future = _resolveHistoryLocations();
    _locationResolution = future;
    return future.whenComplete(() {
      if (identical(_locationResolution, future)) _locationResolution = null;
    });
  }

  Future<Space> renameActiveSpace(String name) async {
    final repository = _spaceRepository;
    final activeSpace = _activeSpace;
    final activeSession = _activeSession;
    final server = _server;
    if (repository == null ||
        activeSpace == null ||
        activeSession == null ||
        server == null) {
      throw StateError('no active space');
    }

    final renamed = await _indexMutex.protect(
      () => repository.renameSpace(activeSpace.id, name),
    );
    _activeSpace = renamed;
    spaceName.value = renamed.name;
    unawaited(_restartAdvertisement());
    return renamed;
  }

  Future<String> start({
    int port = 8080,
    String? newSpaceName,
    String? resumeSpaceId,
    String? selectedAddress,
    String? selectedInterface,
    bool bindSelectedAddress = false,
  }) async {
    if (selectedAddress != null &&
        !SpaceInvite.isSupportedLanIpv4(selectedAddress)) {
      throw ArgumentError.value(
        selectedAddress,
        'selectedAddress',
        '不支持的局域网地址',
      );
    }
    if (_server != null) return _baseUrl;
    debugPrint(
      '[LinkNest] 开始启动本地 HTTP 服务 '
      'resumeSpace=${resumeSpaceId != null} requestedPort=$port',
    );
    if (newSpaceName != null && resumeSpaceId != null) {
      throw ArgumentError(
        'newSpaceName and resumeSpaceId are mutually exclusive',
      );
    }
    final repository = await _prepareStorage();
    late Space space;
    if (resumeSpaceId != null) {
      final existing = repository.findSpace(resumeSpaceId);
      if (existing == null) {
        throw ArgumentError.value(
          resumeSpaceId,
          'resumeSpaceId',
          'does not exist',
        );
      }
      space = existing;
      debugPrint('[LinkNest] 正在继续历史空间 id=${space.id}');
    } else if (newSpaceName != null) {
      final name = newSpaceName.trim();
      if (name.isEmpty) {
        throw ArgumentError.value(newSpaceName, 'newSpaceName', 'is empty');
      }
      space = await repository.createSpace(name);
    } else {
      space =
          repository.latestSpace ??
          await repository.createSpace(
            spaceName.value.trim().isEmpty ? '未命名空间' : spaceName.value,
          );
    }
    spaceName.value = space.name;
    final session = await repository.startSession(space.id);
    space = repository.findSpace(space.id)!;
    _spaceRepository = repository;
    _activeSpace = space;
    _activeSession = session;
    try {
      await _cleanIncoming();
      await _loadActiveFiles();
      await _recoverTransactionsAndOrphans();
      try {
        _hostVersion = await _native.getAppVersion();
      } catch (e) {
        debugPrint('[LinkNest] 读取应用版本失败 reason=${e.runtimeType}');
      }

      _spaceToken = space.accessKey;
      _webSessions.clear();
      _activeClients.clear();
      _clientNames.clear();
      _selectedAddress = selectedAddress;
      _selectedInterface = selectedInterface;
      _bindSelectedAddress = bindSelectedAddress;
      _server = await HttpServer.bind(
        bindSelectedAddress && selectedAddress != null
            ? InternetAddress(selectedAddress)
            : InternetAddress.anyIPv4,
        port,
      );
      _server!.idleTimeout = const Duration(seconds: 30);
      _server!.listen(_handle);
      _baseUrls = selectedAddress == null
          ? await _resolveBaseUrls(_server!.port)
          : ['http://$selectedAddress:${_server!.port}'];
      _baseUrl = _baseUrls.first;
      debugPrint(
        '[LinkNest] 本地 HTTP 服务已启动 port=${_server!.port} '
        'addressCount=${_baseUrls.length} fileCount=${_files.length}',
      );
      unawaited(_restartAdvertisement());
      return _baseUrl;
    } catch (error, stackTrace) {
      await _stopAdvertisement();
      await _server?.close(force: true);
      try {
        await repository.endSession(
          session.id,
          SharingSessionEndReason.interrupted,
        );
      } catch (closeError) {
        debugPrint('[LinkNest] 关闭中断会话记录失败 reason=${closeError.runtimeType}');
      }
      _resetRuntimeState();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 热点重启或局域网地址变化时，重新绑定选定接口并替换邀请地址。
  Future<void> refreshNetworkAddresses({
    String? selectedAddress,
    String? selectedInterface,
  }) async {
    if (selectedAddress != null &&
        !SpaceInvite.isSupportedLanIpv4(selectedAddress)) {
      throw ArgumentError.value(
        selectedAddress,
        'selectedAddress',
        '不支持的局域网地址',
      );
    }
    final server = _server;
    final space = _activeSpace;
    final session = _activeSession;
    if (server == null || space == null || session == null) {
      throw StateError('no active sharing session');
    }
    final previousBaseUrl = _baseUrl;
    if (_bindSelectedAddress &&
        selectedAddress != null &&
        selectedAddress != _selectedAddress) {
      final replacement = await HttpServer.bind(
        InternetAddress(selectedAddress),
        server.port,
      );
      replacement.idleTimeout = const Duration(seconds: 30);
      replacement.listen(_handle);
      _server = replacement;
      await server.close(force: true);
      debugPrint('[LinkNest] 共享服务已切换到新的局域网地址');
    }
    if (selectedAddress != null) _selectedAddress = selectedAddress;
    if (selectedInterface != null) _selectedInterface = selectedInterface;
    final refreshed = _selectedAddress == null
        ? await _resolveBaseUrls(_server!.port)
        : ['http://${_selectedAddress!}:${_server!.port}'];
    _baseUrls = refreshed;
    _baseUrl = refreshed.first;
    debugPrint(
      '[LinkNest] 发起者网络地址已刷新 count=${refreshed.length} '
      'changed=${previousBaseUrl != _baseUrl}',
    );
    await _restartAdvertisement();
  }

  Future<void> pauseNetworkAdvertisement() => _stopAdvertisement();

  Future<List<String>> _resolveBaseUrls(int port) async {
    var addresses = <String>[];
    try {
      addresses = (await _native.getLocalAddresses())
          .map((item) => item['address']?.toString() ?? '')
          .where(SpaceInvite.isSupportedLanIpv4)
          .toSet()
          .toList();
    } catch (error) {
      debugPrint('[LinkNest] 获取本机网络地址失败 reason=${error.runtimeType}');
    }
    if (addresses.isEmpty) {
      try {
        final fallback = await _native.getLocalIp();
        if (SpaceInvite.isSupportedLanIpv4(fallback)) addresses.add(fallback);
      } catch (error) {
        debugPrint('[LinkNest] 获取本机 IP 失败 reason=${error.runtimeType}');
      }
    }
    if (addresses.isEmpty) {
      addresses.add(InternetAddress.loopbackIPv4.address);
    }
    debugPrint('[LinkNest] 本机可用网络地址已解析 count=${addresses.length}');
    return addresses.map((ip) => 'http://$ip:$port').toList(growable: false);
  }

  Future<void> _restartAdvertisement() async {
    _advertisementRetry?.cancel();
    final generation = ++_advertisementGeneration;
    await _advertiseAttempt(generation, 0);
  }

  Future<void> _advertiseAttempt(int generation, int attempt) async {
    final server = _server;
    final space = _activeSpace;
    final session = _activeSession;
    if (generation != _advertisementGeneration ||
        server == null ||
        space == null ||
        session == null) {
      return;
    }
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await _native.startSpaceAdvertisement({
          'pv': '1',
          'sid': space.id,
          'sname': space.name,
          'sess': session.id,
          'token': space.accessKey,
          'addr': _selectedAddress ?? '',
          'port': server.port,
          if (Platform.isIOS) 'interface': _selectedInterface ?? '',
        });
      } else {
        await _discoveryAdvertiser.start(
          spaceId: space.id,
          spaceName: space.name,
          sessionId: session.id,
          token: space.accessKey,
          port: server.port,
        );
      }
      debugPrint('[LinkNest] 局域网空间广告已提交 attempt=$attempt');
    } catch (error) {
      debugPrint(
        '[LinkNest] 局域网空间广告失败 attempt=$attempt reason=${error.runtimeType}',
      );
      if (generation != _advertisementGeneration || attempt >= 3) return;
      _advertisementRetry = Timer(
        Duration(seconds: 2 << attempt),
        () => unawaited(_advertiseAttempt(generation, attempt + 1)),
      );
    }
  }

  Future<void> _stopAdvertisement() async {
    ++_advertisementGeneration;
    _advertisementRetry?.cancel();
    _advertisementRetry = null;
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _native.stopSpaceAdvertisement();
      } catch (error) {
        debugPrint('[LinkNest] 停止局域网空间广告失败 reason=${error.runtimeType}');
      }
    }
    await _discoveryAdvertiser.close();
  }

  Future<SpaceRepository> _prepareStorage() async {
    final prepared = _spaceRepository;
    if (prepared != null) return prepared;
    final docs = _rootOverride ?? await getApplicationDocumentsDirectory();
    _root = _rootOverride ?? Directory('${docs.path}/linknest');
    _filesDir = Directory('${_root.path}/files');
    _incomingDir = Directory('${_root.path}/incoming');
    _thumbsDir = Directory('${_root.path}/thumbs');
    _previewsDir = Directory('${_root.path}/previews');
    _transactionsDir = Directory('${_root.path}/transactions');
    _lostFoundDir = Directory('${_root.path}/lost+found');
    _deleteTransactionsDir = Directory('${_root.path}/delete-transactions');
    _trashDir = Directory('${_root.path}/trash');
    await Future.wait([
      _filesDir.create(recursive: true),
      _incomingDir.create(recursive: true),
      _thumbsDir.create(recursive: true),
      _previewsDir.create(recursive: true),
      _transactionsDir.create(recursive: true),
      _lostFoundDir.create(recursive: true),
      _deleteTransactionsDir.create(recursive: true),
      _trashDir.create(recursive: true),
    ]);
    final repository = await SpaceRepository.open(_root);
    _spaceRepository = repository;
    if (!_storageRecovered) {
      await _recoverDeletionTransactions();
      _storageRecovered = true;
    }
    return repository;
  }

  Future<void> stop() async {
    final repository = _spaceRepository;
    final session = _activeSession;
    debugPrint(
      '[LinkNest] 开始停止本地 HTTP 服务 running=${_server != null} '
      'sessionId=${session?.id ?? "none"}',
    );
    try {
      await _stopAdvertisement();
      await _server?.close(force: true);
      if (repository != null && session != null) {
        await _indexMutex.protect(
          () => repository.endSession(
            session.id,
            SharingSessionEndReason.stopped,
          ),
        );
      }
    } finally {
      _resetRuntimeState();
      debugPrint('[LinkNest] 本地 HTTP 服务已停止');
    }
  }

  void _resetRuntimeState() {
    _server = null;
    _baseUrl = '';
    _selectedAddress = null;
    _selectedInterface = null;
    _bindSelectedAddress = false;
    _baseUrls = const [];
    _spaceToken = '';
    _webSessions.clear();
    _activeClients.clear();
    _clientNames.clear();
    _activeSession = null;
    _activeSpace = null;
    _spaceRepository = null;
  }

  Future<void> _cleanIncoming() async {
    await for (final entity in _incomingDir.list()) {
      if (entity is File && entity.path.endsWith('.part')) {
        try {
          await entity.delete();
          debugPrint('[LinkNest] 已清理上次遗留的未完成上传');
        } catch (e) {
          debugPrint('[LinkNest] 清理遗留未完成上传失败 reason=${e.runtimeType}');
        }
      }
    }
    for (final directory in [_thumbsDir, _previewsDir]) {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (e) {
            debugPrint('[LinkNest] 清理遗留预览缓存失败 reason=${e.runtimeType}');
          }
        }
      }
    }
  }

  Future<void> _loadActiveFiles() async {
    final repository = _spaceRepository!;
    final space = _activeSpace!;
    final changed = <FileRecord>[];
    _files.clear();
    for (var record in repository.filesForSpace(space.id)) {
      final thumbnail = File('${_thumbsDir.path}/${record.id}.jpg');
      final preview = File('${_previewsDir.path}/${record.id}.jpg');
      final hasCache = await _validJpeg(thumbnail) || await _validJpeg(preview);
      if (hasCache && record.previewStatus != PreviewStatus.ready) {
        record = record.copyWith(previewStatus: PreviewStatus.ready);
        changed.add(record);
      }
      _files.add(record);
    }
    if (changed.isNotEmpty) {
      await _indexMutex.protect(() => repository.replaceFiles(changed));
      debugPrint('[LinkNest] 已恢复预览元数据 records=${changed.length}');
    }
  }

  Future<void> _recoverTransactionsAndOrphans() async {
    final repository = _spaceRepository!;
    final activeSpace = _activeSpace!;
    final activeSession = _activeSession!;
    await for (final entity in _transactionsDir.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.tmp')) {
        await entity.delete();
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) throw const FormatException('invalid transaction');
        var record = FileRecord.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (record.spaceId.isEmpty || record.sessionId.isEmpty) {
          record = record.copyWith(
            spaceId: activeSpace.id,
            sessionId: activeSession.id,
          );
        }
        final original = File('${_filesDir.path}/${record.id}');
        final paired = File(pairedVideoPath(record.id));
        final spaceFiles = repository.filesForSpace(record.spaceId);
        final hasId = repository.files.any((item) => item.id == record.id);
        final duplicate = spaceFiles.any(
          (item) => item.id != record.id && _sameContent(item, record),
        );
        final complete =
            await original.exists() &&
            (!record.isLivePhoto || await paired.exists());
        if (complete && !hasId && !duplicate) {
          await repository.addFile(record);
          if (record.spaceId == activeSpace.id) _files.add(record);
          debugPrint('[LinkNest] 已恢复文件提交事务 id=${record.id}');
        } else if (complete && duplicate) {
          await original.delete();
          if (await paired.exists()) await paired.delete();
        }
        await entity.delete();
      } catch (e) {
        debugPrint('[LinkNest] 文件提交事务无效 reason=${e.runtimeType}');
        await _moveToLostFound(entity, prefix: 'transaction');
      }
    }

    final knownIds = <String>{
      for (final record in repository.files) record.id,
      for (final record in repository.files.where((item) => item.isLivePhoto))
        '${record.id}.paired',
    };
    await for (final entity in _filesDir.list()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (!knownIds.contains(name)) {
          await _moveToLostFound(entity, prefix: 'orphan');
          debugPrint('[LinkNest] 已将孤立媒体移入 lost+found id=$name');
        }
      }
    }
  }

  Future<void> _moveToLostFound(File source, {required String prefix}) async {
    final name = source.uri.pathSegments.last;
    final destination = File(
      '${_lostFoundDir.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}-$name',
    );
    try {
      await source.rename(destination.path);
    } catch (_) {
      await source.copy(destination.path);
      await source.delete();
    }
  }

  Future<({String id, String name})?> _resolveRequestParticipant(
    HttpRequest req,
    String sessionId,
  ) async {
    final raw = req.headers.value(AppIdentity.header);
    if (raw == null) return null; // Web 与旧 App 继续使用原接口。
    if (!AppIdentity.validId.hasMatch(raw)) {
      throw const UploadFailure(400, 'INVALID_IDENTITY', '上传身份无效，请重新打开 App');
    }
    return _indexMutex.protect(() async {
      if (_activeSession?.id != sessionId) {
        throw const UploadFailure(409, 'SESSION_CHANGED', '空间已关闭或重新开启，请重新连接');
      }
      final id = AppIdentity.forSpace(_activeSpace!.id, raw);
      final name = await _spaceRepository!.resolveParticipantName(
        _activeSpace!.id,
        id,
      );
      final ip = req.connectionInfo?.remoteAddress.address;
      if (ip != null) _clientNames[ip] = name;
      return (id: id, name: name);
    });
  }

  Future<void> _handle(HttpRequest req) async {
    final clientIp = req.connectionInfo?.remoteAddress.address;
    final path = req.uri.path;
    final segments = req.uri.pathSegments;
    try {
      if (path == '/api/web-session') {
        await _handleWebSession(req);
        return;
      }
      if (path == '/api/discovery' && req.method == 'GET') {
        final space = _activeSpace;
        final session = _activeSession;
        if (space == null || session == null) {
          await _serveError(req, 'SPACE_CLOSED', '空间已关闭', 503);
          return;
        }
        await _serveOk(req, {
          'spaceId': space.id,
          'sessionId': session.id,
          'spaceName': space.name,
        });
        return;
      }
      if (path.startsWith('/api/') && !_isAuthorized(req)) {
        await _serveError(req, 'AUTH_REQUIRED', '空间凭证无效或已过期', 401);
        return;
      }
      if (path.startsWith('/api/') &&
          clientIp != null &&
          clientIp != '127.0.0.1' &&
          clientIp != '::1') {
        _activeClients[clientIp] = DateTime.now();
      }
      if (path == '/api/meta') {
        final ip = clientIp ?? 'unknown';
        final participant = await _resolveRequestParticipant(
          req,
          _activeSession!.id,
        );
        final activeSpace =
            _spaceRepository?.findSpace(_activeSpace!.id) ?? _activeSpace!;
        await _serveOk(req, {
          'spaceId': activeSpace.id,
          'sessionId': _activeSession!.id,
          'spaceName': activeSpace.name,
          'spaceUpdatedAt': activeSpace.updatedAt.millisecondsSinceEpoch,
          'visitorName':
              participant?.name ??
              _clientNames.putIfAbsent(ip, generateVisitorName),
          if (participant != null) 'uploaderId': participant.id,
          'protocolVersion': linkNestProtocolVersion,
          'hostVersion': _hostVersion,
          'capabilities': linkNestCapabilities,
        });
      } else if (path == '/api/files' && req.method == 'GET') {
        await _serveOk(req, _files.map((e) => e.toPublicJson()).toList());
      } else if (path == '/api/upload' && req.method == 'POST') {
        await _handleUpload(req);
      } else if (path == '/api/clients') {
        await _serveOk(req, _clients());
      } else if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'files') {
        final id = segments[2];
        switch (segments[3]) {
          case 'thumbnail':
            await _handleThumb(req, id);
            break;
          case 'preview':
            await _handlePreview(req, id);
            break;
          case 'download':
            await _handleDownload(req, id);
            break;
          default:
            await _serveError(req, 'NOT_FOUND', '资源不存在', 404);
        }
      } else if (req.method == 'GET') {
        await _serveAsset(req, path);
      } else {
        await _serveError(req, 'NOT_FOUND', '资源不存在', 404);
      }
    } on UploadFailure catch (e) {
      await _serveError(req, e.code, e.message, e.status);
    } catch (e) {
      debugPrint(
        '[LinkNest] HTTP 请求处理失败 method=${req.method} path=$path '
        'reason=${e.runtimeType}',
      );
      try {
        await _serveError(req, 'INTERNAL_ERROR', '服务端处理失败', 500);
      } catch (_) {}
    }
  }

  Future<void> _handleWebSession(HttpRequest req) async {
    if (req.method != 'POST') {
      await _serveError(req, 'METHOD_NOT_ALLOWED', '请求方法不支持', 405);
      return;
    }
    final token = _bearerToken(req);
    if (token == null || !_secureEquals(token, _spaceToken)) {
      await _serveError(req, 'AUTH_REQUIRED', '空间凭证无效或已过期', 401);
      return;
    }
    final session = _randomToken();
    _webSessions.add(session);
    req.response.cookies.add(
      Cookie('linknest_session', session)
        ..httpOnly = true
        ..sameSite = SameSite.strict
        ..path = '/',
    );
    await _serveOk(req, {'protocolVersion': linkNestProtocolVersion});
  }

  bool _isAuthorized(HttpRequest req) {
    final bearer = _bearerToken(req);
    if (bearer != null && _secureEquals(bearer, _spaceToken)) return true;
    for (final cookie in req.cookies) {
      if (cookie.name == 'linknest_session' &&
          _webSessions.contains(cookie.value)) {
        return true;
      }
    }
    return false;
  }

  String? _bearerToken(HttpRequest req) {
    final value = req.headers.value(HttpHeaders.authorizationHeader);
    if (value == null || !value.startsWith('Bearer ')) return null;
    final token = value.substring('Bearer '.length).trim();
    return token.isEmpty ? null : token;
  }

  bool _secureEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return difference == 0;
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<void> _handleUpload(HttpRequest req) async {
    if (_activeUploads >= uploadPolicy.maxConcurrentUploads) {
      await _serveError(req, 'TOO_MANY_UPLOADS', '同时上传任务过多，请稍后重试', 429);
      return;
    }
    _activeUploads++;
    debugPrint(
      '[LinkNest] 收到上传请求 active=$_activeUploads '
      'contentLength=${req.contentLength}',
    );
    try {
      await _handleUploadRequest(req);
    } finally {
      _activeUploads--;
      debugPrint(
        '[LinkNest] 上传请求处理结束 active=$_activeUploads '
        'status=${req.response.statusCode}',
      );
    }
  }

  Future<void> _handleUploadRequest(HttpRequest req) async {
    if (req.contentLength > 0) uploadPolicy.checkRequestSize(req.contentLength);
    final contentType = req.headers.contentType;
    final boundary = contentType?.parameters['boundary'];
    if (contentType == null ||
        !contentType.mimeType.startsWith('multipart/form-data') ||
        boundary == null) {
      await _serveError(
        req,
        'INVALID_MULTIPART',
        '请求必须使用 multipart/form-data',
        400,
      );
      return;
    }

    final requestSessionId = _activeSession!.id;
    String uploader = '';
    var sawFile = false;
    UploadFailure? deferredFailure;
    final pending = <_PendingFile>[];
    _PendingFile? livePhoto;
    _PendingFile? liveVideo;
    try {
      final transformer = MimeMultipartTransformer(boundary);
      await for (final part in transformer.bind(_limitedRequest(req))) {
        if (deferredFailure != null) {
          await part.drain<void>();
          continue;
        }
        final disposition = part.headers['content-disposition'] ?? '';
        final fieldName = _dispositionValue(disposition, 'name');
        final filename = _dispositionValue(disposition, 'filename');
        if (fieldName == 'uploader') {
          uploader = await _readStreamAsString(
            part,
            maxBytes: uploadPolicy.maxUploaderBytes,
          );
        } else if ((fieldName == 'file' ||
                fieldName == 'photo' ||
                fieldName == 'pairedVideo') &&
            filename != null &&
            filename.isNotEmpty) {
          sawFile = true;
          uploadPolicy.checkFileCount(
            pending.length +
                (livePhoto == null ? 0 : 1) +
                (liveVideo == null ? 0 : 1) +
                1,
          );
          final safeName = _sanitizeFileName(filename);
          try {
            uploadPolicy.checkMediaName(safeName);
            await _checkStorage();
          } on UploadFailure catch (error) {
            deferredFailure = error;
            await part.drain<void>();
            continue;
          }
          final staged = await _stageFile(
            part,
            safeName,
            declaredMimeType: part.headers['content-type'],
          );
          if (fieldName == 'photo') {
            if (livePhoto != null) {
              throw const UploadFailure(
                400,
                'INVALID_LIVE_PHOTO',
                'Live Photo 只能包含一个照片资源',
              );
            }
            livePhoto = staged;
          } else if (fieldName == 'pairedVideo') {
            if (liveVideo != null) {
              throw const UploadFailure(
                400,
                'INVALID_LIVE_PHOTO',
                'Live Photo 只能包含一个配对视频资源',
              );
            }
            liveVideo = staged;
          } else {
            pending.add(staged);
          }
        }
      }

      if (deferredFailure != null) throw deferredFailure;

      if (!sawFile) {
        await _serveError(req, 'NO_FILE', '请求中没有文件', 400);
        return;
      }

      final participant = await _resolveRequestParticipant(
        req,
        requestSessionId,
      );
      if (participant != null) uploader = participant.name;
      final uploaderId = participant?.id ?? '';
      final created = <FileRecord>[];
      if (livePhoto != null || liveVideo != null) {
        if (pending.isNotEmpty || livePhoto == null || liveVideo == null) {
          throw const UploadFailure(
            400,
            'INVALID_LIVE_PHOTO',
            'Live Photo 必须且只能同时上传照片与配对视频',
          );
        }
        final record = await _commitLivePhoto(
          livePhoto,
          liveVideo,
          uploader,
          uploaderId: uploaderId,
          sessionId: requestSessionId,
        );
        if (record != null) created.add(record);
      }
      for (final staged in pending) {
        final record = await _commit(
          staged,
          uploader,
          uploaderId: uploaderId,
          sessionId: requestSessionId,
        );
        if (record != null) created.add(record);
      }
      await _serveOk(req, created.map((e) => e.toPublicJson()).toList());
    } finally {
      for (final staged in pending) {
        if (await staged.file.exists()) {
          try {
            await staged.file.delete();
          } catch (_) {}
        }
      }
      for (final staged in [livePhoto, liveVideo].whereType<_PendingFile>()) {
        if (await staged.file.exists()) {
          try {
            await staged.file.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<_PendingFile> _stageFile(
    Stream<List<int>> stream,
    String filename, {
    String? declaredMimeType,
  }) async {
    final file = File('${_incomingDir.path}/${_newId()}.part');
    RandomAccessFile? writer;
    var size = 0;
    var completed = false;
    try {
      writer = await file.open(mode: FileMode.write);
      await for (final chunk in stream) {
        size += chunk.length;
        uploadPolicy.checkSize(size);
        await writer.writeFrom(chunk);
      }
      await writer.flush();
      await writer.close();
      writer = null;
      await _checkStorage();
      final digest = await sha256.bind(file.openRead()).single;
      final pending = _PendingFile(
        file: file,
        name: filename,
        size: size,
        sha256: digest.toString(),
        format: MediaFormats.resolve(
          filename,
          declaredMimeType: declaredMimeType,
        ),
      );
      completed = true;
      debugPrint(
        '[LinkNest] 媒体文件暂存完成 size=$size '
        'kind=${pending.format.kind} mime=${pending.format.mimeType}',
      );
      return pending;
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 28) {
        throw const UploadFailure(507, 'INSUFFICIENT_STORAGE', '设备剩余存储空间不足');
      }
      rethrow;
    } finally {
      await writer?.close();
      if (!completed && await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<FileRecord?> _commit(
    _PendingFile pending,
    String uploader, {
    String uploaderId = '',
    String? sessionId,
  }) {
    return _indexMutex.protect(() async {
      if (sessionId != null && _activeSession?.id != sessionId) {
        throw const UploadFailure(409, 'SESSION_CHANGED', '空间已关闭或重新开启，请重新连接');
      }
      if (_files.any((record) => record.sha256 == pending.sha256)) {
        await pending.file.delete();
        return null;
      }
      final id = _newId();
      final destination = File('${_filesDir.path}/$id');
      final record = FileRecord(
        id: id,
        name: pending.name,
        size: pending.size,
        kind: pending.format.kind,
        mimeType: pending.format.mimeType,
        previewStatus: pending.format.previewSupported
            ? PreviewStatus.unknown
            : PreviewStatus.unsupported,
        uploader: uploader,
        uploaderId: uploaderId,
        sha256: pending.sha256,
        uploadedAt: DateTime.now(),
        spaceId: _activeSpace!.id,
        sessionId: _activeSession!.id,
      );
      final transaction = await _writeTransaction(record);
      try {
        try {
          await pending.file.rename(destination.path);
        } catch (_) {
          await pending.file.copy(destination.path);
          await pending.file.delete();
        }
        await _spaceRepository!.addFile(record);
      } catch (_) {
        if (await destination.exists()) await destination.delete();
        if (await transaction.exists()) await transaction.delete();
        rethrow;
      }
      _files.add(record);
      try {
        await transaction.delete();
      } catch (error) {
        debugPrint('[LinkNest] 清理已提交文件事务失败 reason=${error.runtimeType}');
      }
      debugPrint(
        '[LinkNest] 文件已提交 id=$id size=${record.size} '
        'mime=${record.mimeType} livePhoto=${record.isLivePhoto}',
      );
      if (record.kind == 'image') {
        unawaited(resolveHistoryLocations());
      }
      return record;
    });
  }

  Future<FileRecord?> _commitLivePhoto(
    _PendingFile photo,
    _PendingFile pairedVideo,
    String uploader, {
    String uploaderId = '',
    String? sessionId,
  }) {
    return _indexMutex.protect(() async {
      if (sessionId != null && _activeSession?.id != sessionId) {
        throw const UploadFailure(409, 'SESSION_CHANGED', '空间已关闭或重新开启，请重新连接');
      }
      final duplicate = _files.any(
        (record) =>
            record.isLivePhoto &&
            record.photoResource!.sha256 == photo.sha256 &&
            record.pairedVideo!.sha256 == pairedVideo.sha256,
      );
      if (duplicate) {
        await photo.file.delete();
        await pairedVideo.file.delete();
        return null;
      }
      if (photo.format.kind != 'image' || pairedVideo.format.kind != 'video') {
        throw const UploadFailure(
          400,
          'INVALID_LIVE_PHOTO',
          'Live Photo 资源类型不正确',
        );
      }
      final id = _newId();
      final photoDestination = File(filePath(id));
      final videoDestination = File(pairedVideoPath(id));
      final photoResource = MediaResource(
        name: photo.name,
        size: photo.size,
        mimeType: photo.format.mimeType,
        sha256: photo.sha256,
      );
      final videoResource = MediaResource(
        name: pairedVideo.name,
        size: pairedVideo.size,
        mimeType: pairedVideo.format.mimeType,
        sha256: pairedVideo.sha256,
      );
      final record = FileRecord(
        id: id,
        name: photo.name,
        size: photo.size + pairedVideo.size,
        kind: 'image',
        mimeType: photo.format.mimeType,
        previewStatus: PreviewStatus.unknown,
        uploader: uploader,
        uploaderId: uploaderId,
        sha256: '',
        uploadedAt: DateTime.now(),
        spaceId: _activeSpace!.id,
        sessionId: _activeSession!.id,
        photoResource: photoResource,
        pairedVideo: videoResource,
      );
      final transaction = await _writeTransaction(record);
      try {
        await _moveStaged(photo.file, photoDestination);
        await _moveStaged(pairedVideo.file, videoDestination);
        await _spaceRepository!.addFile(record);
      } catch (_) {
        if (await photoDestination.exists()) await photoDestination.delete();
        if (await videoDestination.exists()) await videoDestination.delete();
        if (await transaction.exists()) await transaction.delete();
        rethrow;
      }
      _files.add(record);
      try {
        await transaction.delete();
      } catch (error) {
        debugPrint(
          '[LinkNest] 清理已提交 Live Photo 事务失败 reason=${error.runtimeType}',
        );
      }
      debugPrint(
        '[LinkNest] Live Photo 已提交 id=$id '
        'photoBytes=${photo.size} videoBytes=${pairedVideo.size}',
      );
      unawaited(resolveHistoryLocations());
      return record;
    });
  }

  Future<void> _moveStaged(File source, File destination) async {
    try {
      await source.rename(destination.path);
    } catch (_) {
      await source.copy(destination.path);
      await source.delete();
    }
  }

  bool _sameContent(FileRecord left, FileRecord right) {
    if (left.isLivePhoto != right.isLivePhoto) return false;
    if (!left.isLivePhoto) {
      return left.sha256.isNotEmpty && left.sha256 == right.sha256;
    }
    return left.photoResource!.sha256 == right.photoResource!.sha256 &&
        left.pairedVideo!.sha256 == right.pairedVideo!.sha256;
  }

  Future<File> _writeTransaction(FileRecord record) async {
    final transaction = File('${_transactionsDir.path}/${record.id}.json');
    final temporary = File('${transaction.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(record.toStorageJson()),
      flush: true,
    );
    await temporary.rename(transaction.path);
    return transaction;
  }

  Future<FileRecord?> importFile(
    File source,
    String name,
    String uploader, {
    void Function()? checkCancelled,
  }) async {
    final importSessionId = _activeSession?.id;
    if (importSessionId == null) {
      throw const UploadFailure(409, 'SESSION_CHANGED', '请先开启空间再上传');
    }
    final importUploaderId = hostUploaderId;
    checkCancelled?.call();
    final safeName = _sanitizeFileName(name);
    uploadPolicy.checkMediaName(safeName);
    final size = await source.length();
    uploadPolicy.checkSize(size);
    await _checkStorage(incomingBytes: size);
    checkCancelled?.call();
    final staged = File('${_incomingDir.path}/${_newId()}.part');
    try {
      // Keep the picker-owned source until the import commits. HostDataSource
      // can retain it for an explicit retry if staging, hashing, or the index
      // transaction fails.
      final digest = await _copyAndHash(
        source,
        staged,
        checkCancelled: checkCancelled,
      );
      checkCancelled?.call();
      final record = await _commit(
        _PendingFile(
          file: staged,
          name: safeName,
          size: size,
          sha256: digest.toString(),
          format: MediaFormats.ofName(safeName),
        ),
        uploader,
        uploaderId: importUploaderId,
        sessionId: importSessionId,
      );
      try {
        await source.delete();
      } catch (error) {
        debugPrint(
          '[LinkNest] 清理导入选择器缓存失败 '
          'name=$safeName error=${error.runtimeType}',
        );
      }
      return record;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<FileRecord?> importLivePhoto(
    File photo,
    String photoName,
    File pairedVideo,
    String pairedVideoName,
    String uploader, {
    void Function()? checkCancelled,
  }) async {
    final importSessionId = _activeSession?.id;
    if (importSessionId == null) {
      throw const UploadFailure(409, 'SESSION_CHANGED', '请先开启空间再上传');
    }
    final importUploaderId = hostUploaderId;
    checkCancelled?.call();
    final safePhotoName = _sanitizeFileName(photoName);
    final safeVideoName = _sanitizeFileName(pairedVideoName);
    uploadPolicy.checkMediaName(safePhotoName);
    uploadPolicy.checkMediaName(safeVideoName);
    final photoSize = await photo.length();
    final videoSize = await pairedVideo.length();
    uploadPolicy.checkFileCount(2);
    uploadPolicy.checkSize(photoSize);
    uploadPolicy.checkSize(videoSize);
    uploadPolicy.checkRequestSize(photoSize + videoSize);
    await _checkStorage(incomingBytes: photoSize + videoSize);
    final stagedPhoto = File('${_incomingDir.path}/${_newId()}.part');
    final stagedVideo = File('${_incomingDir.path}/${_newId()}.part');
    try {
      final photoDigest = await _copyAndHash(
        photo,
        stagedPhoto,
        checkCancelled: checkCancelled,
      );
      final videoDigest = await _copyAndHash(
        pairedVideo,
        stagedVideo,
        checkCancelled: checkCancelled,
      );
      checkCancelled?.call();
      final record = await _commitLivePhoto(
        _PendingFile(
          file: stagedPhoto,
          name: safePhotoName,
          size: photoSize,
          sha256: photoDigest.toString(),
          format: MediaFormats.ofName(safePhotoName),
        ),
        _PendingFile(
          file: stagedVideo,
          name: safeVideoName,
          size: videoSize,
          sha256: videoDigest.toString(),
          format: MediaFormats.ofName(safeVideoName),
        ),
        uploader,
        uploaderId: importUploaderId,
        sessionId: importSessionId,
      );
      for (final source in [photo, pairedVideo]) {
        try {
          await source.delete();
        } catch (error) {
          debugPrint(
            '[LinkNest] 清理 Live Photo 选择器缓存失败 '
            'path=${source.path} error=${error.runtimeType}',
          );
        }
      }
      return record;
    } finally {
      for (final staged in [stagedPhoto, stagedVideo]) {
        if (await staged.exists()) await staged.delete();
      }
    }
  }

  Future<Digest> _copyAndHash(
    File source,
    File destination, {
    void Function()? checkCancelled,
  }) async {
    RandomAccessFile? reader;
    RandomAccessFile? writer;
    ByteConversionSink? hashInput;
    Digest? digest;
    try {
      reader = await source.open();
      writer = await destination.open(mode: FileMode.write);
      hashInput = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((values) {
          digest = values.single;
        }),
      );
      while (true) {
        checkCancelled?.call();
        final chunk = await reader.read(1024 * 1024);
        if (chunk.isEmpty) break;
        checkCancelled?.call();
        await writer.writeFrom(chunk);
        hashInput.add(chunk);
      }
      await writer.flush();
      hashInput.close();
      hashInput = null;
      return digest!;
    } finally {
      await reader?.close();
      await writer?.close();
      hashInput?.close();
    }
  }

  Future<void> _checkStorage({int incomingBytes = 0}) async {
    try {
      final available = await _native.getFreeDiskBytes();
      uploadPolicy.checkAvailable(available, incomingBytes: incomingBytes);
    } on UploadFailure {
      rethrow;
    } catch (e) {
      debugPrint('[LinkNest] 获取可用存储空间失败 reason=${e.runtimeType}');
    }
  }

  Future<void> _handleDownload(HttpRequest req, String id) async {
    if (req.method != 'GET' && req.method != 'HEAD') {
      await _serveError(req, 'METHOD_NOT_ALLOWED', '请求方法不受支持', 405);
      return;
    }
    final record = _findById(id);
    final role = req.uri.queryParameters['resource'] ?? 'photo';
    if (role != 'photo' && role != 'pairedVideo') {
      await _serveError(req, 'INVALID_RESOURCE', '媒体资源角色无效', 400);
      return;
    }
    if (role == 'pairedVideo' && record?.pairedVideo == null) {
      await _serveError(req, 'NOT_FOUND', '配对视频不存在', 404);
      return;
    }
    final resource = role == 'pairedVideo'
        ? record?.pairedVideo
        : record?.primaryResource;
    final file = File(
      role == 'pairedVideo' ? pairedVideoPath(id) : filePath(id),
    );
    if (record == null || !await file.exists()) {
      await _serveError(req, 'NOT_FOUND', '文件不存在', 404);
      return;
    }
    final selectedResource = resource!;
    final fileLength = await file.length();
    final etag = '"${selectedResource.sha256}"';
    final requestedRange = req.headers.value('range');
    final ifRange = req.headers.value('if-range');
    _ByteRange? range;
    if (req.method == 'GET' &&
        requestedRange != null &&
        (ifRange == null || ifRange == etag)) {
      range = _parseByteRange(requestedRange, fileLength);
      if (range == null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set('accept-ranges', 'bytes');
        req.response.headers.set('content-range', 'bytes */$fileLength');
        req.response.headers.set(HttpHeaders.contentLengthHeader, 0);
        debugPrint(
          '[LinkNest] 视频 Range 请求被拒绝 id=$id valueLength='
          '${requestedRange.length} total=$fileLength',
        );
        await req.response.close();
        return;
      }
    }
    debugPrint(
      '[LinkNest] 文件下载请求 id=$id role=$role method=${req.method} '
      'range=${range == null ? 'full' : '${range.start}-${range.end}'} '
      'total=$fileLength mime=${selectedResource.mimeType}',
    );
    req.response.bufferOutput = false;
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      selectedResource.mimeType,
    );
    req.response.headers.set(
      'content-disposition',
      _contentDisposition(selectedResource.name),
    );
    req.response.headers.set('accept-ranges', 'bytes');
    req.response.headers.set(HttpHeaders.etagHeader, etag);
    req.response.headers.set('cache-control', 'private, no-store');
    if (range != null) {
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(
        'content-range',
        'bytes ${range.start}-${range.end}/$fileLength',
      );
      req.response.headers.set(HttpHeaders.contentLengthHeader, range.length);
    } else {
      req.response.headers.set(HttpHeaders.contentLengthHeader, fileLength);
    }
    if (req.method == 'GET') {
      await req.response.addStream(
        file.openRead(range?.start, range == null ? null : range.end + 1),
      );
    }
    await req.response.close();
  }

  Future<void> _handleThumb(HttpRequest req, String id) async {
    final data = await thumbnail(id);
    if (data.isEmpty) {
      await _serveError(req, 'PREVIEW_UNAVAILABLE', '无法生成缩略图', 404);
      return;
    }
    req.response.headers.contentType = ContentType('image', 'jpeg');
    req.response.add(data);
    await req.response.close();
  }

  Future<void> _handlePreview(HttpRequest req, String id) async {
    final data = await preview(id);
    if (data.isEmpty) {
      await _serveError(req, 'PREVIEW_UNAVAILABLE', '无法生成预览', 404);
      return;
    }
    req.response.headers.contentType = ContentType('image', 'jpeg');
    req.response.add(data);
    await req.response.close();
  }

  Future<Uint8List> thumbnail(String id) =>
      _renderPreview(id, target: 512, directory: _thumbsDir);

  Future<Uint8List> historyThumbnail(String id) async {
    final repository = await _prepareStorage();
    final record = repository.findFile(id);
    if (record == null) return Uint8List(0);
    return _renderPreview(
      id,
      target: 512,
      directory: _thumbsDir,
      storedRecord: record,
    );
  }

  Future<Uint8List> preview(String id) =>
      _renderPreview(id, target: 2000, directory: _previewsDir);

  Future<Uint8List> _renderPreview(
    String id, {
    required int target,
    required Directory directory,
    FileRecord? storedRecord,
  }) async {
    final record = storedRecord ?? _findById(id);
    final original = File('${_filesDir.path}/$id');
    if (record == null || !await original.exists()) return Uint8List(0);
    if (record.previewStatus == PreviewStatus.unsupported ||
        record.previewStatus == PreviewStatus.failed) {
      return Uint8List(0);
    }
    final cacheKey = '${directory.path}/$id';
    final mutex = _previewMutexes.putIfAbsent(cacheKey, AsyncMutex.new);
    return mutex.protect(() async {
      final cached = File('${directory.path}/$id.jpg');
      if (await _validJpeg(cached)) return cached.readAsBytes();

      File? temporary;
      try {
        final bytes = await _previewLimiter.protect(
          () => _native.makeThumbnail(
            original.path,
            kind: record.kind,
            target: target,
            name: record.name,
          ),
        );
        debugPrint(
          '[LinkNest] 预览文件已生成 id=$id target=$target bytes=${bytes.length}',
        );
        if (!_validJpegBytes(bytes)) {
          await _setPreviewStatus(id, PreviewStatus.failed);
          return Uint8List(0);
        }
        temporary = File('${cached.path}.${_newId()}.tmp');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(cached.path);
        await _setPreviewStatus(id, PreviewStatus.ready);
        return bytes;
      } catch (e) {
        debugPrint(
          '[LinkNest] 生成预览失败 id=$id target=$target reason=${e.runtimeType}',
        );
        await _setPreviewStatus(id, PreviewStatus.failed);
        return Uint8List(0);
      } finally {
        if (temporary != null && await temporary.exists()) {
          try {
            await temporary.delete();
          } catch (_) {}
        }
      }
    });
  }

  Future<bool> _validJpeg(File file) async {
    if (!await file.exists()) return false;
    RandomAccessFile? handle;
    try {
      final length = await file.length();
      if (length < 5) throw const FormatException('JPEG is too short');
      handle = await file.open();
      final prefix = await handle.read(3);
      await handle.setPosition(length - 2);
      final suffix = await handle.read(2);
      if (!_hasJpegMarkers(prefix, suffix)) {
        throw const FormatException('JPEG markers are invalid');
      }
      return true;
    } catch (e) {
      debugPrint(
        '[LinkNest] 预览缓存无效 cacheName=${file.uri.pathSegments.last} '
        'reason=${e.runtimeType}',
      );
      await handle?.close();
      handle = null;
      try {
        await file.delete();
      } catch (_) {}
      return false;
    } finally {
      await handle?.close();
    }
  }

  bool _validJpegBytes(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return _hasJpegMarkers(
      bytes.sublist(0, 3),
      bytes.sublist(bytes.length - 2),
    );
  }

  bool _hasJpegMarkers(List<int> prefix, List<int> suffix) =>
      prefix.length == 3 &&
      prefix[0] == 0xff &&
      prefix[1] == 0xd8 &&
      prefix[2] == 0xff &&
      suffix.length == 2 &&
      suffix[0] == 0xff &&
      suffix[1] == 0xd9;

  Future<void> _setPreviewStatus(String id, String status) {
    return _indexMutex.protect(() async {
      final index = _files.indexWhere((record) => record.id == id);
      final repository = _spaceRepository;
      if (repository == null) return;
      final previous = index >= 0 ? _files[index] : repository.findFile(id);
      if (previous == null || previous.previewStatus == status) return;
      final updated = previous.copyWith(previewStatus: status);
      await repository.replaceFile(updated);
      if (index >= 0) _files[index] = updated;
    });
  }

  Future<void> _resolveHistoryLocations() async {
    final repository = await _prepareStorage();
    final candidates = repository.files
        .where(
          (record) =>
              record.kind == 'image' &&
              (record.photoLocation == null ||
                  record.photoLocation!.status == PhotoLocationStatus.unknown ||
                  record.photoLocation!.status == PhotoLocationStatus.pending),
        )
        .toList();
    if (candidates.isEmpty) return;
    debugPrint('[LinkNest] 开始解析历史照片地点 count=${candidates.length}');
    for (final candidate in candidates) {
      final current = repository.findFile(candidate.id);
      if (current == null) continue;
      NativePhotoCoordinates? coordinates;
      final stored = current.photoLocation;
      if (stored?.latitude != null && stored?.longitude != null) {
        coordinates = NativePhotoCoordinates(
          stored!.latitude!,
          stored.longitude!,
        );
      } else {
        final source = File(filePath(current.id));
        if (!await source.exists()) continue;
        try {
          coordinates = await _native.readPhotoCoordinates(source.path);
        } catch (error) {
          debugPrint(
            '[LinkNest] 无法读取照片 GPS id=${current.id} '
            'reason=${error.runtimeType}',
          );
          continue;
        }
      }
      if (coordinates == null) {
        await _replacePhotoLocation(
          repository,
          current,
          const PhotoLocation(status: PhotoLocationStatus.noGps),
        );
        continue;
      }
      String? label;
      for (final record in repository.files) {
        final location = record.photoLocation;
        if (location?.status == PhotoLocationStatus.resolved &&
            location?.label != null &&
            location?.latitude != null &&
            location?.longitude != null &&
            (location!.latitude! - coordinates.latitude).abs() < 0.0005 &&
            (location.longitude! - coordinates.longitude).abs() < 0.0005) {
          label = location.label;
          break;
        }
      }
      if (label == null) {
        try {
          label = await _native.reverseGeocode(
            coordinates.latitude,
            coordinates.longitude,
          );
        } catch (error) {
          debugPrint(
            '[LinkNest] 照片地点反向解析不可用 id=${current.id} '
            'reason=${error.runtimeType}',
          );
        }
      }
      await _replacePhotoLocation(
        repository,
        current,
        PhotoLocation(
          status: label == null
              ? PhotoLocationStatus.pending
              : PhotoLocationStatus.resolved,
          latitude: coordinates.latitude,
          longitude: coordinates.longitude,
          label: label,
        ),
      );
      if (label != null) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    debugPrint('[LinkNest] 历史照片地点解析结束');
  }

  Future<void> _replacePhotoLocation(
    SpaceRepository repository,
    FileRecord record,
    PhotoLocation location,
  ) {
    return _indexMutex.protect(() async {
      final latest = repository.findFile(record.id);
      if (latest == null) return;
      final updated = latest.copyWith(photoLocation: location);
      await repository.replaceFile(updated);
      final activeIndex = _files.indexWhere((file) => file.id == updated.id);
      if (activeIndex >= 0) _files[activeIndex] = updated;
      debugPrint(
        '[LinkNest] 照片地点状态已更新 id=${record.id} '
        'status=${location.status}',
      );
    });
  }

  Future<void> deleteHistoryFiles(String spaceId, Set<String> fileIds) async {
    if (fileIds.isEmpty) return;
    await _deleteHistory(spaceId, fileIds, removeSpace: false);
  }

  Future<void> deleteHistorySpace(String spaceId) async {
    final repository = await _prepareStorage();
    final ids = repository
        .filesForSpace(spaceId)
        .map((file) => file.id)
        .toSet();
    await _deleteHistory(spaceId, ids, removeSpace: true);
  }

  Future<void> _deleteHistory(
    String spaceId,
    Set<String> fileIds, {
    required bool removeSpace,
  }) {
    return _indexMutex.protect(() async {
      final repository = await _prepareStorage();
      if (running && _activeSpace?.id == spaceId) {
        throw StateError('正在共享的空间不能删除');
      }
      final space = repository.findSpace(spaceId);
      if (space == null) throw StateError('历史空间不存在');
      final records = fileIds.map(repository.findFile).whereType<FileRecord>();
      if (records.length != fileIds.length ||
          records.any((record) => record.spaceId != spaceId)) {
        throw StateError('待删除文件不属于该空间');
      }

      final transactionId = 'delete-${_newId()}';
      final trash = Directory('${_trashDir.path}/$transactionId');
      await trash.create(recursive: true);
      final moves = <Map<String, String>>[];
      for (final id in fileIds) {
        moves.addAll([
          {'source': filePath(id), 'trash': '${trash.path}/files--$id'},
          {
            'source': pairedVideoPath(id),
            'trash': '${trash.path}/files--$id.paired',
          },
          {
            'source': '${_thumbsDir.path}/$id.jpg',
            'trash': '${trash.path}/thumbs--$id.jpg',
          },
          {
            'source': '${_previewsDir.path}/$id.jpg',
            'trash': '${trash.path}/previews--$id.jpg',
          },
        ]);
      }
      final transaction = File(
        '${_deleteTransactionsDir.path}/$transactionId.json',
      );
      Future<void> writeTransaction(String phase) async {
        final temporary = File('${transaction.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({
            'id': transactionId,
            'spaceId': spaceId,
            'fileIds': fileIds.toList(),
            'removeSpace': removeSpace,
            'phase': phase,
            'moves': moves,
          }),
          flush: true,
        );
        if (await transaction.exists()) await transaction.delete();
        await temporary.rename(transaction.path);
      }

      await writeTransaction('prepared');
      try {
        for (final move in moves) {
          final source = File(move['source']!);
          if (await source.exists()) {
            await _moveFile(source, File(move['trash']!));
          }
        }
        await writeTransaction('filesMoved');
        if (removeSpace) {
          await repository.removeSpace(spaceId);
        } else {
          await repository.removeFiles(fileIds);
        }
        await writeTransaction('stateCommitted');
        _files.removeWhere((file) => fileIds.contains(file.id));
        await _finishDeletionTransaction(transaction, trash);
        debugPrint(
          '[LinkNest] 历史删除事务已提交 spaceId=$spaceId '
          'files=${fileIds.length} removeSpace=$removeSpace',
        );
      } catch (_) {
        await _rollbackDeletionMoves(moves);
        if (await transaction.exists()) await transaction.delete();
        if (await trash.exists()) await trash.delete(recursive: true);
        rethrow;
      }
    });
  }

  Future<void> _recoverDeletionTransactions() async {
    final repository = _spaceRepository!;
    await for (final entity in _deleteTransactionsDir.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.tmp')) {
        await entity.delete();
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) throw const FormatException('invalid deletion');
        final transactionId = decoded['id']?.toString() ?? '';
        final spaceId = decoded['spaceId']?.toString() ?? '';
        final removeSpace = decoded['removeSpace'] == true;
        final ids = (decoded['fileIds'] as List? ?? const [])
            .map((id) => id.toString())
            .toSet();
        final moves = (decoded['moves'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (move) => {
                'source': move['source']?.toString() ?? '',
                'trash': move['trash']?.toString() ?? '',
              },
            )
            .toList();
        final stateStillOwnsData = removeSpace
            ? repository.findSpace(spaceId) != null
            : ids.any((id) => repository.findFile(id) != null);
        final trash = Directory('${_trashDir.path}/$transactionId');
        if (stateStillOwnsData) {
          await _rollbackDeletionMoves(moves);
          debugPrint('[LinkNest] 已回滚中断的历史删除事务');
        } else {
          debugPrint('[LinkNest] 已完成中断的历史删除事务清理');
        }
        await _finishDeletionTransaction(entity, trash);
      } catch (error) {
        debugPrint('[LinkNest] 历史删除事务无效 reason=${error.runtimeType}');
        await _moveToLostFound(entity, prefix: 'delete-transaction');
      }
    }
  }

  Future<void> _rollbackDeletionMoves(List<Map<String, String>> moves) async {
    for (final move in moves.reversed) {
      final sourcePath = move['source'] ?? '';
      final trashPath = move['trash'] ?? '';
      if (sourcePath.isEmpty || trashPath.isEmpty) continue;
      final source = File(sourcePath);
      final trashed = File(trashPath);
      if (!await source.exists() && await trashed.exists()) {
        await _moveFile(trashed, source);
      }
    }
  }

  Future<void> _finishDeletionTransaction(
    File transaction,
    Directory trash,
  ) async {
    if (await trash.exists()) await trash.delete(recursive: true);
    if (await transaction.exists()) await transaction.delete();
  }

  Future<void> _moveFile(File source, File destination) async {
    await destination.parent.create(recursive: true);
    try {
      await source.rename(destination.path);
    } catch (_) {
      await source.copy(destination.path);
      await source.delete();
    }
  }

  FileRecord? _findById(String id) {
    for (final record in _files) {
      if (record.id == id) return record;
    }
    return null;
  }

  List<Map<String, dynamic>> _clients() {
    final now = DateTime.now();
    _activeClients.removeWhere(
      (_, last) => now.difference(last).inSeconds > 30,
    );
    return _activeClients.keys
        .map(
          (ip) => {
            'ip': ip,
            'name': _clientNames[ip] ?? '未知',
            'lastSeen': _activeClients[ip]!.millisecondsSinceEpoch,
          },
        )
        .toList();
  }

  String _newId() {
    _idSequence = (_idSequence + 1) & 0xfffff;
    return '${DateTime.now().microsecondsSinceEpoch}-$_idSequence';
  }

  String? _dispositionValue(String contentDisposition, String key) {
    return RegExp('$key="([^"]*)"').firstMatch(contentDisposition)?.group(1);
  }

  String _contentDisposition(String name) {
    var ascii = name
        .replaceAll(RegExp(r'[^\x20-\x7e]'), '_')
        .replaceAll(RegExp(r'["\\]'), '_')
        .trim();
    if (ascii.isEmpty) ascii = 'download';
    if (ascii.length > 150) ascii = ascii.substring(0, 150);
    final encoded = Uri.encodeComponent(name)
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');
    return "attachment; filename=\"$ascii\"; filename*=UTF-8''$encoded";
  }

  Stream<List<int>> _limitedRequest(Stream<List<int>> stream) async* {
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      uploadPolicy.checkRequestSize(total);
      yield chunk;
    }
  }

  Future<String> _readStreamAsString(
    Stream<List<int>> stream, {
    required int maxBytes,
  }) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const UploadFailure(413, 'FIELD_TOO_LARGE', '上传字段超过大小限制');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes).trim();
  }

  String _sanitizeFileName(String raw) {
    final basename = raw.replaceAll('\\', '/').split('/').last;
    final sanitized = basename
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_')
        .trim();
    if (sanitized.isEmpty) {
      throw const UploadFailure(400, 'INVALID_FILENAME', '文件名不能为空');
    }
    if (utf8.encode(sanitized).length > uploadPolicy.maxFilenameBytes) {
      throw const UploadFailure(413, 'FILENAME_TOO_LONG', '文件名超过长度限制');
    }
    return sanitized;
  }

  Future<void> _serveAsset(HttpRequest req, String path) async {
    final relative = path == '/' ? 'index.html' : path.substring(1);
    try {
      final data = await rootBundle.load('assets/web/$relative');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      req.response.headers.contentType = ContentType.parse(
        _assetMimeType(relative),
      );
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      req.response.headers.set(
        HttpHeaders.cacheControlHeader,
        'no-store, no-cache, must-revalidate',
      );
      req.response.headers.set('pragma', 'no-cache');
      req.response.headers.set('expires', '0');
      req.response.add(bytes);
      await req.response.close();
    } catch (_) {
      await _serveError(req, 'NOT_FOUND', '资源不存在', 404);
    }
  }

  String _assetMimeType(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.js')) return 'text/javascript; charset=utf-8';
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  Future<void> _serveOk(HttpRequest req, Object? data) async {
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({'ok': true, 'data': data}));
    await req.response.close();
  }

  Future<void> _serveError(
    HttpRequest req,
    String code,
    String message,
    int status,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode({'ok': false, 'error': message, 'code': code}),
    );
    await req.response.close();
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
}

_ByteRange? _parseByteRange(String value, int fileLength) {
  if (fileLength <= 0 || !value.startsWith('bytes=')) return null;
  final specification = value.substring('bytes='.length).trim();
  if (specification.isEmpty || specification.contains(',')) return null;
  final separator = specification.indexOf('-');
  if (separator < 0 || specification.indexOf('-', separator + 1) >= 0) {
    return null;
  }
  final startText = specification.substring(0, separator).trim();
  final endText = specification.substring(separator + 1).trim();
  if (startText.isEmpty) {
    final suffixLength = int.tryParse(endText);
    if (suffixLength == null || suffixLength <= 0) return null;
    final start = suffixLength >= fileLength ? 0 : fileLength - suffixLength;
    return _ByteRange(start, fileLength - 1);
  }
  final start = int.tryParse(startText);
  if (start == null || start < 0 || start >= fileLength) return null;
  if (endText.isEmpty) return _ByteRange(start, fileLength - 1);
  final requestedEnd = int.tryParse(endText);
  if (requestedEnd == null || requestedEnd < start) return null;
  final end = requestedEnd >= fileLength ? fileLength - 1 : requestedEnd;
  return _ByteRange(start, end);
}
