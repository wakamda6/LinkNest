import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_record.dart';
import 'guest_api_client.dart';
import 'guest_media_cache.dart';
import 'guest_transfer_runtime.dart';
import 'media_format.dart';
import 'space_data_source.dart';
import 'space_invite.dart';

typedef GuestApiClientFactory = GuestApiClient Function(SpaceInvite invite);
typedef GuestReconnectAddressProvider = Future<List<String>> Function();
typedef GuestInviteChanged = Future<void> Function(
  SpaceHandshake handshake,
  SpaceInvite invite,
);

class GuestDataSource
    implements
        SpaceDataSource,
        GuestLifecycleDataSource,
        NetworkVideoDataSource,
        UploaderIdentityDataSource {
  GuestDataSource(
    this._client, {
    required SpaceHandshake handshake,
    Future<Directory> Function()? temporaryDirectoryProvider,
    this._mediaCache,
    GuestTransferRuntime? transferRuntime,
    GuestApiClientFactory? clientFactory,
    this.reconnectAddressProvider,
    this.onInviteChanged,
    this.metadataRefreshInterval = const Duration(seconds: 3),
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _transferRuntime = transferRuntime,
       _clientFactory =
           clientFactory ??
           ((invite) => GuestApiClient(
             invite: invite,
             installationId: _client.installationId,
             requestTimeout: const Duration(seconds: 3),
           )),
       _spaceId = handshake.spaceId,
       _capabilities = handshake.capabilities,
       _lastMetadataRefreshAt = DateTime.now(),
       spaceName = ValueNotifier(handshake.spaceName),
       participantName = handshake.visitorName,
       uploaderId = handshake.uploaderId {
    _backgroundExpirationSubscription = transferRuntime?.backgroundTimeExpired
        .listen((_) => _handleBackgroundTimeExpired());
  }

  static const int _thumbnailCacheBytes = 32 * 1024 * 1024;
  static const int _previewCacheBytes = 48 * 1024 * 1024;

  GuestApiClient _client;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  GuestMediaCache? _mediaCache;
  final GuestTransferRuntime? _transferRuntime;
  final GuestApiClientFactory _clientFactory;
  final GuestReconnectAddressProvider? reconnectAddressProvider;
  final GuestInviteChanged? onInviteChanged;
  final String _spaceId;
  Set<String> _capabilities;
  final Duration metadataRefreshInterval;
  DateTime _lastMetadataRefreshAt;
  final _ByteLruCache _thumbnailCache = _ByteLruCache(
    maximumEntries: 64,
    maximumBytes: _thumbnailCacheBytes,
  );
  final _ByteLruCache _previewCache = _ByteLruCache(
    maximumEntries: 8,
    maximumBytes: _previewCacheBytes,
  );
  final _AsyncRequestLimiter _thumbnailLimiter = _AsyncRequestLimiter(4);
  final _AsyncRequestLimiter _previewLimiter = _AsyncRequestLimiter(2);
  final _AsyncRequestLimiter _uploadLimiter = _AsyncRequestLimiter(1);
  final _AsyncRequestLimiter _downloadLimiter = _AsyncRequestLimiter(2);
  final Map<String, Future<Uint8List>> _thumbnailRequests = {};
  final Map<String, Future<Uint8List>> _previewRequests = {};
  final Map<String, FileRecord> _knownFiles = {};
  final Map<String, int> _mediaCacheGenerations = {};
  final List<PickedMedia> _pendingUploads = [];
  final Set<SpaceTransferCancellation> _activeTransfers = {};
  final Set<SpaceTransferCancellation> _activeUploadTransfers = {};
  StreamSubscription<void>? _backgroundExpirationSubscription;
  Future<void>? _reconnectInFlight;
  bool _closed = false;
  bool _backgroundUploadInterrupted = false;
  bool _transferRuntimeRunning = false;
  int _downloadSequence = 0;
  int _consecutiveConnectionFailures = 0;
  DateTime? _lastNativeProgressAt;
  int _lastNativeProgressPercent = -1;

  @override
  final ValueNotifier<String> spaceName;

  @override
  final ValueNotifier<SpaceConnectionState> connectionState = ValueNotifier(
    SpaceConnectionState.connected,
  );

  @override
  final ValueNotifier<List<String>> pendingUploadNames = ValueNotifier(
    const [],
  );

  @override
  String participantName;

  @override
  String uploaderId;

  @override
  SpaceDataSourceCapabilities get capabilities =>
      SpaceDataSourceCapabilities.full;

  Future<void> attachMediaCache({
    required GuestMediaCache mediaCache,
  }) async {
    if (_closed) {
      await mediaCache.close();
      return;
    }
    _mediaCache = mediaCache;
  }

  @override
  Future<List<FileRecord>> listFiles() async {
    _ensureOpen();
    try {
      final files = await _client.listFiles();
      await _refreshMetadataIfDue();
      _ensureOpen();
      final ids = files.map((record) => record.id).toSet();
      for (final removedId in _knownFiles.keys.where(
        (id) => !ids.contains(id),
      )) {
        _invalidateMediaCache(removedId, reason: 'removed');
      }
      for (final record in files) {
        final previous = _knownFiles[record.id];
        if (previous != null && !previous.hasSameMediaContentAs(record)) {
          _invalidateMediaCache(record.id, reason: 'media_changed');
        }
      }
      _thumbnailCache.retainIds(ids);
      _previewCache.retainIds(ids);
      _knownFiles
        ..removeWhere((id, _) => !ids.contains(id))
        ..addEntries(files.map((record) => MapEntry(record.id, record)));
      await _reconcileDiskCache(files);
      _markConnected();
      return files;
    } catch (error) {
      _recordConnectionFailure(error, fromList: true);
      rethrow;
    }
  }

  @override
  Future<Uint8List> thumbnail(String id) => _loadCached(
    id,
    resource: 'thumbnail',
    diskRole: 'thumbnail',
    cache: _thumbnailCache,
    inFlight: _thumbnailRequests,
    limiter: _thumbnailLimiter,
    loader: _client.thumbnail,
  );

  @override
  Future<Uint8List> preview(String id) => _loadCached(
    id,
    resource: 'preview',
    diskRole: 'preview',
    cache: _previewCache,
    inFlight: _previewRequests,
    limiter: _previewLimiter,
    loader: _client.preview,
  );

  @override
  NetworkVideoPlaybackSource? videoPlaybackSource(FileRecord record) {
    if (!_capabilities.contains('videoRangeV1')) return null;
    if (kDebugMode) {
      debugPrint('[LinkNest] 访客视频播放源 id=${record.id} source=host');
    }
    return _client.videoPlaybackSource(record);
  }

  @override
  Future<AddFilesResult> addPickedMedia(
    List<PickedMedia> files, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) => _uploadLimiter.run(
    () => _processPickedMedia(
      files,
      onProgress: onProgress,
      cancellation: cancellation,
    ),
  );

  @override
  Future<AddFilesResult> retryPendingUploads({
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) => _uploadLimiter.run(() async {
    _ensureOpen();
    final pending = List<PickedMedia>.of(_pendingUploads);
    _pendingUploads.clear();
    _publishPendingUploads();
    return _processPickedMedia(
      pending,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  });

  Future<AddFilesResult> _processPickedMedia(
    List<PickedMedia> files, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    final transfer = cancellation ?? SpaceTransferCancellation();
    _activeUploadTransfers.add(transfer);
    await _beginTransfer(
      transfer,
      direction: 'upload',
      fileName: files.isEmpty ? '媒体文件' : files.first.name,
      totalBytes: 0,
    );
    var added = 0;
    var skipped = 0;
    final unsupported = <String>[];
    final failed = <String>[];
    var cancelled = false;
    try {
      for (var index = 0; index < files.length; index++) {
        final picked = files[index];
        final file = File(picked.path);
        if (transfer.isCancelled) {
          cancelled = true;
          await _retainOrDelete(files.skip(index));
          break;
        }
        final photoFormat = MediaFormats.ofName(picked.name);
        final pairedFormat = picked.isLivePhoto
            ? MediaFormats.ofName(picked.pairedVideoName)
            : null;
        final accepted =
            photoFormat.isAcceptedMedia &&
            (!picked.isLivePhoto ||
                (photoFormat.kind == 'image' &&
                    pairedFormat!.isAcceptedMedia &&
                    pairedFormat.kind == 'video'));
        if (!accepted) {
          unsupported.add(picked.name);
          debugPrint('[LinkNest] 访客跳过非图片或视频文件');
          await _deletePicked(picked);
          continue;
        }
        var consumed = false;
        try {
          _ensureOpen();
          if (!await file.exists()) {
            throw const GuestApiException(
              'UPLOAD_FILE_MISSING',
              '待上传文件不存在，请重新从相册选择。',
            );
          }
          final pairedVideo = picked.isLivePhoto
              ? File(picked.pairedVideoPath)
              : null;
          if (pairedVideo != null && !await pairedVideo.exists()) {
            throw const GuestApiException(
              'UPLOAD_FILE_MISSING',
              'Live Photo 配对视频不存在，请重新从相册选择。',
            );
          }
          final total =
              await file.length() +
              (pairedVideo == null ? 0 : await pairedVideo.length());
          _reportTransferProgress(
            SpaceTransferProgress(
              fileName: picked.name,
              completedBytes: 0,
              totalBytes: total,
            ),
            direction: 'upload',
            onProgress: onProgress,
          );
          final records = picked.isLivePhoto
              ? await _client.uploadLivePhoto(
                  file,
                  pairedVideo!,
                  photoName: picked.name,
                  pairedVideoName: picked.pairedVideoName,
                  uploader: participantName,
                  cancellation: transfer,
                  onProgress: (completed, total) => _reportTransferProgress(
                    SpaceTransferProgress(
                      fileName: picked.name,
                      completedBytes: completed,
                      totalBytes: total,
                    ),
                    direction: 'upload',
                    onProgress: onProgress,
                  ),
                )
              : await _client.uploadFile(
                  file,
                  name: picked.name,
                  uploader: participantName,
                  cancellation: transfer,
                  onProgress: (completed, total) => _reportTransferProgress(
                    SpaceTransferProgress(
                      fileName: picked.name,
                      completedBytes: completed,
                      totalBytes: total,
                    ),
                    direction: 'upload',
                    onProgress: onProgress,
                  ),
                );
          _ensureOpen();
          consumed = true;
          if (records.isEmpty) {
            skipped++;
          } else {
            added += records.length;
          }
          _reportTransferProgress(
            SpaceTransferProgress(
              fileName: picked.name,
              completedBytes: total,
              totalBytes: total,
            ),
            direction: 'upload',
            onProgress: onProgress,
          );
          _markConnected();
        } on SpaceTransferCancelledException {
          cancelled = true;
          await _retainOrDelete(files.skip(index));
          break;
        } catch (error) {
          failed.add(picked.name);
          _recordConnectionFailure(error, fromList: false);
          debugPrint(
            '[LinkNest] 访客上传失败 '
            'error=${error.runtimeType}',
          );
          if (error is GuestApiException &&
              error.code == 'UPLOAD_FILE_MISSING') {
            await _deletePicked(picked);
          } else {
            await _retainOrDelete([picked]);
          }
          if (_shouldStopBatch(error)) {
            await _retainOrDelete(files.skip(index + 1));
            break;
          }
        } finally {
          if (consumed) await _deletePicked(picked);
        }
      }
    } finally {
      _activeUploadTransfers.remove(transfer);
      await _endTransfer(transfer);
    }
    return AddFilesResult(
      added: added,
      skipped: skipped,
      unsupported: unsupported,
      failed: failed,
      pending: _pendingUploads.length,
      cancelled: cancelled,
    );
  }

  @override
  Future<void> discardPendingUploads() => _discardPendingUploads();

  @override
  Future<LocalOriginal> materializeOriginal(
    FileRecord record, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) => _downloadLimiter.run(() async {
    _ensureOpen();
    final transfer = cancellation ?? SpaceTransferCancellation();
    transfer.throwIfCancelled();
    await _beginTransfer(
      transfer,
      direction: 'download',
      fileName: record.name,
      totalBytes: record.size,
    );
    try {
      final mediaCache = _mediaCache;
      final liveKeys = record.isLivePhoto && mediaCache != null
          ? _livePhotoKeys(record)
          : null;
      if (liveKeys != null) {
        final cached = await mediaCache!.acquireFiles(liveKeys);
        if (cached != null) {
          _markConnected();
          return LocalOriginal(
            cached.files.first.path,
            pairedVideoPath: cached.files.last.path,
            onDispose: cached.release,
          );
        }
      }
      final root = await _temporaryDirectoryProvider();
      _ensureOpen();
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}linknest-downloads',
      );
      final sequence = ++_downloadSequence;
      final extension = _safeExtension(record.name);
      final target = File(
        '${directory.path}${Platform.pathSeparator}${record.id}-$sequence$extension',
      );
      final pairedTarget = record.isLivePhoto
          ? File(
              '${directory.path}${Platform.pathSeparator}'
              '${record.id}-$sequence-paired${_safeExtension(record.pairedVideo!.name)}',
            )
          : null;
      _reportTransferProgress(
        SpaceTransferProgress(
          fileName: record.name,
          completedBytes: 0,
          totalBytes: record.size,
        ),
        direction: 'download',
        onProgress: onProgress,
      );
      try {
        await _client.downloadFile(
          record,
          target,
          cancellation: transfer,
          onProgress: (completed, total) => _reportTransferProgress(
            SpaceTransferProgress(
              fileName: record.name,
              completedBytes: completed,
              totalBytes: record.isLivePhoto ? record.size : total,
            ),
            direction: 'download',
            onProgress: onProgress,
          ),
        );
        if (pairedTarget != null) {
          final photoBytes = record.primaryResource.size;
          await _client.downloadFile(
            record,
            pairedTarget,
            resource: record.pairedVideo,
            cancellation: transfer,
            onProgress: (completed, _) => _reportTransferProgress(
              SpaceTransferProgress(
                fileName: record.name,
                completedBytes: photoBytes + completed,
                totalBytes: record.size,
              ),
              direction: 'download',
              onProgress: onProgress,
            ),
          );
        }
        _ensureOpen();
        _markConnected();
      } catch (error) {
        _recordConnectionFailure(error, fromList: false);
        if (await target.exists()) await target.delete();
        if (pairedTarget != null && await pairedTarget.exists()) {
          await pairedTarget.delete();
        }
        rethrow;
      }
      if (liveKeys != null && pairedTarget != null) {
        try {
          await mediaCache!.storeFiles({
            liveKeys.first: target,
            liveKeys.last: pairedTarget,
          });
          final cached = await mediaCache.acquireFiles(liveKeys);
          if (cached != null) {
            if (await target.exists()) await target.delete();
            if (await pairedTarget.exists()) await pairedTarget.delete();
            return LocalOriginal(
              cached.files.first.path,
              pairedVideoPath: cached.files.last.path,
              onDispose: cached.release,
            );
          }
        } on Object catch (error) {
          debugPrint(
            '[LinkNest] Live Photo 缓存提交失败 id=${record.id} '
            'reason=${error.runtimeType}',
          );
        }
      }
      return LocalOriginal(
        target.path,
        pairedVideoPath: pairedTarget?.path,
        onDispose: () async {
          try {
            if (await target.exists()) await target.delete();
            if (pairedTarget != null && await pairedTarget.exists()) {
              await pairedTarget.delete();
            }
          } catch (error) {
            debugPrint(
              '[LinkNest] 清理访客下载缓存失败 id=${record.id} '
              'error=${error.runtimeType}',
            );
          }
        },
      );
    } finally {
      await _endTransfer(transfer);
    }
  });

  List<GuestMediaCacheKey> _livePhotoKeys(FileRecord record) {
    final photo = record.photoResource!;
    final video = record.pairedVideo!;
    return [
      GuestMediaCacheKey(
        spaceId: _spaceId,
        fileId: record.id,
        role: 'livePhoto',
        digest: photo.sha256,
        extension: _safeExtension(photo.name),
      ),
      GuestMediaCacheKey(
        spaceId: _spaceId,
        fileId: record.id,
        role: 'livePairedVideo',
        digest: video.sha256,
        extension: _safeExtension(video.name),
      ),
    ];
  }

  @override
  bool consumeBackgroundInterruptedUpload() {
    final value = _backgroundUploadInterrupted;
    _backgroundUploadInterrupted = false;
    return value;
  }

  @override
  Future<void> reconnect() {
    final active = _reconnectInFlight;
    if (active != null) return active;
    late Future<void> reconnectFuture;
    reconnectFuture = _reconnect().whenComplete(() {
      if (identical(_reconnectInFlight, reconnectFuture)) {
        _reconnectInFlight = null;
      }
    });
    _reconnectInFlight = reconnectFuture;
    return reconnectFuture;
  }

  Future<void> _reconnect() async {
    _ensureOpen();
    final currentInvite = _client.invite;
    final candidates = <SpaceInvite>[currentInvite];
    try {
      final addresses = await reconnectAddressProvider?.call() ?? const [];
      for (final address in addresses) {
        if (!SpaceInvite.isSupportedLanIpv4(address)) continue;
        final invite = SpaceInvite(
          baseUri: currentInvite.baseUri.replace(host: address),
          token: currentInvite.token,
        );
        if (candidates.any((item) => item.baseUri == invite.baseUri)) continue;
        candidates.add(invite);
      }
    } catch (error) {
      debugPrint(
        '[LinkNest] 访客重连时查询地址失败 '
        'reason=${error.runtimeType}',
      );
    }

    debugPrint('[LinkNest] 访客开始重连 candidates=${candidates.length}');
    Object? lastError;
    for (var index = 0; index < candidates.length; index++) {
      final invite = candidates[index];
      final candidateClient = _clientFactory(invite);
      var accepted = false;
      try {
        final handshake = await candidateClient.handshake();
        _ensureOpen();
        _applyHandshake(handshake);
        final previousClient = _client;
        _client = candidateClient;
        _capabilities = handshake.capabilities;
        _lastMetadataRefreshAt = DateTime.now();
        accepted = true;
        previousClient.close();
        _markConnected();
        debugPrint(
          '[LinkNest] 访客重连成功 candidateIndex=$index '
          'addressChanged=${invite.baseUri != currentInvite.baseUri}',
        );
        try {
          await onInviteChanged?.call(handshake, invite);
        } catch (error) {
          debugPrint(
            '[LinkNest] 更新访客历史地址失败 '
            'reason=${error.runtimeType}',
          );
        }
        return;
      } catch (error) {
        lastError = error;
        debugPrint(
          '[LinkNest] 访客重连地址尝试失败 index=$index '
          'reason=${error.runtimeType}',
        );
      } finally {
        if (!accepted) candidateClient.close();
      }
    }

    try {
      if (lastError != null) throw lastError;
      throw const GuestApiException(
        'CONNECTION_FAILED',
        '无法连接 Host，请确认已接入当前热点后重试。',
      );
    } catch (error, stackTrace) {
      _recordConnectionFailure(error, fromList: true);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _refreshMetadataIfDue() async {
    final now = DateTime.now();
    if (now.difference(_lastMetadataRefreshAt) < metadataRefreshInterval) {
      return;
    }
    final handshake = await _client.handshake();
    _ensureOpen();
    _applyHandshake(handshake);
    _lastMetadataRefreshAt = now;
  }

  void _applyHandshake(SpaceHandshake handshake) {
    if (handshake.spaceId != _spaceId) {
      throw const GuestApiException('SPACE_MISMATCH', '当前地址已经指向其他空间，请退出后重新加入。');
    }
    participantName = handshake.visitorName;
    uploaderId = handshake.uploaderId;
    if (spaceName.value == handshake.spaceName) return;
    spaceName.value = handshake.spaceName;
    debugPrint('[LinkNest] 已从发起者元数据更新空间名称');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final transfer in _activeTransfers.toList()) {
      transfer.cancel();
    }
    await _backgroundExpirationSubscription?.cancel();
    _backgroundExpirationSubscription = null;
    await _stopTransferRuntime();
    _client.close();
    await _discardPendingUploads();
    _thumbnailCache.clear();
    _previewCache.clear();
    _knownFiles.clear();
    _mediaCacheGenerations.clear();
    _thumbnailRequests.clear();
    _previewRequests.clear();
    await _mediaCache?.close();
    _setConnectionState(
      const SpaceConnectionState(
        status: SpaceConnectionStatus.closed,
        message: '访客连接已关闭。',
      ),
      reason: 'client_closed',
    );
    spaceName.dispose();
    connectionState.dispose();
    pendingUploadNames.dispose();
  }

  void _markConnected() {
    if (_closed) return;
    _consecutiveConnectionFailures = 0;
    if (connectionState.value.status != SpaceConnectionStatus.connected) {
      _setConnectionState(
        SpaceConnectionState.connected,
        reason: 'request_succeeded',
      );
    }
  }

  void _recordConnectionFailure(Object error, {required bool fromList}) {
    if (_closed || error is SpaceTransferCancelledException) return;
    if (error is GuestApiException) {
      if (const {
        'INCOMPATIBLE_PROTOCOL',
        'MISSING_CAPABILITY',
      }.contains(error.code)) {
        _setConnectionState(
          SpaceConnectionState(
            status: SpaceConnectionStatus.incompatible,
            message: error.message,
          ),
          reason: error.code,
        );
        return;
      }
      if (error.statusCode == 401 || error.code == 'AUTH_REQUIRED') {
        _consecutiveConnectionFailures = 3;
        _setConnectionState(
          SpaceConnectionState(
            status: SpaceConnectionStatus.disconnected,
            message: '空间凭证已失效，请返回并重新扫描当前空间码。',
            consecutiveFailures: _consecutiveConnectionFailures,
          ),
          reason: 'AUTH_REQUIRED',
        );
        return;
      }
      if (!fromList && !_isTransientConnectionError(error)) return;
    } else if (!fromList) {
      return;
    }

    _consecutiveConnectionFailures++;
    final disconnected = _consecutiveConnectionFailures >= 3;
    _setConnectionState(
      SpaceConnectionState(
        status: disconnected
            ? SpaceConnectionStatus.disconnected
            : SpaceConnectionStatus.degraded,
        message: disconnected
            ? '与 Host 的连接已中断，请检查热点后重新连接。'
            : '与 Host 的连接不稳定，正在降低刷新频率。',
        consecutiveFailures: _consecutiveConnectionFailures,
      ),
      reason: error is GuestApiException
          ? error.code
          : error.runtimeType.toString(),
    );
  }

  void _setConnectionState(
    SpaceConnectionState next, {
    required String reason,
  }) {
    final previous = connectionState.value;
    if (kDebugMode &&
        (previous.status != next.status ||
            previous.consecutiveFailures != next.consecutiveFailures)) {
      debugPrint(
        '[LinkNest] 访客连接状态变化 ${previous.status.name}->${next.status.name} '
        'failures=${next.consecutiveFailures} reason=$reason',
      );
    }
    connectionState.value = next;
  }

  static bool _isTransientConnectionError(GuestApiException error) => const {
    'CONNECTION_FAILED',
    'CONNECTION_TIMEOUT',
    'DOWNLOAD_TIMEOUT',
    'CLIENT_CLOSED',
  }.contains(error.code);

  static bool _shouldStopBatch(Object error) {
    if (error is! GuestApiException) return false;
    return error.statusCode == 401 ||
        const {
          'AUTH_REQUIRED',
          'INCOMPATIBLE_PROTOCOL',
          'MISSING_CAPABILITY',
          'CONNECTION_FAILED',
          'CONNECTION_TIMEOUT',
          'CLIENT_CLOSED',
          'DATA_SOURCE_CLOSED',
        }.contains(error.code);
  }

  Future<void> _retainOrDelete(Iterable<PickedMedia> files) async {
    for (final picked in files) {
      if (_closed) {
        await _deletePicked(picked);
        continue;
      }
      final file = File(picked.path);
      if (!await file.exists()) continue;
      if (!_pendingUploads.any((item) => item.path == picked.path)) {
        _pendingUploads.add(picked);
      }
    }
    _publishPendingUploads();
  }

  Future<void> _discardPendingUploads() async {
    final pending = List<PickedMedia>.of(_pendingUploads);
    _pendingUploads.clear();
    _publishPendingUploads();
    for (final picked in pending) {
      await _deletePicked(picked);
    }
  }

  Future<void> _deletePicked(PickedMedia picked) async {
    for (final path in [picked.path, picked.pairedVideoPath]) {
      if (path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint(
          '[LinkNest] 清理访客选择器缓存失败 '
          'name=${picked.name} error=${error.runtimeType}',
        );
      }
    }
  }

  void _publishPendingUploads() {
    if (_closed) return;
    pendingUploadNames.value = List.unmodifiable(
      _pendingUploads.map((item) => item.name),
    );
  }

  Future<void> _beginTransfer(
    SpaceTransferCancellation transfer, {
    required String direction,
    required String fileName,
    required int totalBytes,
  }) async {
    final shouldStartRuntime = _activeTransfers.isEmpty;
    _activeTransfers.add(transfer);
    if (!shouldStartRuntime || _transferRuntime == null) return;
    _lastNativeProgressAt = null;
    _lastNativeProgressPercent = -1;
    try {
      await _transferRuntime.start(
        direction: direction,
        fileName: fileName,
        totalBytes: totalBytes,
      );
      _transferRuntimeRunning = true;
      debugPrint('[LinkNest] 访客传输运行时已启动 direction=$direction');
    } catch (error) {
      debugPrint(
        '[LinkNest] 启动访客传输运行时失败 '
        'reason=${error.runtimeType}',
      );
    }
  }

  Future<void> _endTransfer(SpaceTransferCancellation transfer) async {
    _activeTransfers.remove(transfer);
    if (_activeTransfers.isNotEmpty) return;
    await _stopTransferRuntime();
  }

  Future<void> _stopTransferRuntime() async {
    if (_transferRuntime == null || !_transferRuntimeRunning) return;
    _transferRuntimeRunning = false;
    try {
      await _transferRuntime.stop();
      debugPrint('[LinkNest] 访客传输运行时已停止');
    } catch (error) {
      debugPrint(
        '[LinkNest] 停止访客传输运行时失败 '
        'reason=${error.runtimeType}',
      );
    }
  }

  void _reportTransferProgress(
    SpaceTransferProgress progress, {
    required String direction,
    TransferProgressCallback? onProgress,
  }) {
    onProgress?.call(progress);
    final runtime = _transferRuntime;
    if (runtime == null) return;
    final total = progress.totalBytes;
    final percent = total <= 0
        ? 0
        : ((progress.completedBytes * 100) ~/ total).clamp(0, 100);
    final now = DateTime.now();
    final lastAt = _lastNativeProgressAt;
    if (percent == _lastNativeProgressPercent &&
        lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 1)) {
      return;
    }
    _lastNativeProgressAt = now;
    _lastNativeProgressPercent = percent;
    unawaited(
      runtime
          .update(progress, direction: direction)
          .catchError(
            (Object error) => debugPrint(
              '[LinkNest] 更新访客传输运行时失败 '
              'reason=${error.runtimeType}',
            ),
          ),
    );
  }

  void _handleBackgroundTimeExpired() {
    if (_closed || _activeTransfers.isEmpty) return;
    _backgroundUploadInterrupted = _activeUploadTransfers.isNotEmpty;
    debugPrint(
      '[LinkNest] iOS 访客后台执行时间已到期 '
      'active=${_activeTransfers.length} '
      'upload=$_backgroundUploadInterrupted',
    );
    for (final transfer in _activeTransfers.toList()) {
      transfer.cancel();
    }
  }

  Future<Uint8List> _loadCached(
    String id, {
    required String resource,
    required String diskRole,
    required _ByteLruCache cache,
    required Map<String, Future<Uint8List>> inFlight,
    required _AsyncRequestLimiter limiter,
    required Future<Uint8List> Function(String id) loader,
  }) {
    _ensureOpen();
    final cached = cache.get(id);
    if (cached != null) {
      debugPrint(
        '[LinkNest] 访客媒体读取完成 '
        'id=$id resource=$resource source=memory',
      );
      return Future.value(cached);
    }
    final active = inFlight[id];
    if (active != null) return active;
    final generation = _mediaCacheGenerations[id] ?? 0;
    final mediaCache = _mediaCache;
    final record = _knownFiles[id];
    final diskKey = record == null || record.primaryResource.sha256.isEmpty
        ? null
        : GuestMediaCacheKey(
            spaceId: _spaceId,
            fileId: id,
            role: diskRole,
            digest: record.primaryResource.sha256,
            extension: 'jpg',
          );

    late final Future<Uint8List> request;
    request = limiter
        .run(() async {
          _ensureOpen();
          if (mediaCache != null && diskKey != null) {
            try {
              final diskBytes = await mediaCache.readBytes(diskKey);
              _ensureOpen();
              if (diskBytes != null) {
                if (_isJpeg(diskBytes)) {
                  cache.put(id, diskBytes);
                  debugPrint(
                    '[LinkNest] 访客媒体读取完成 '
                    'id=$id resource=$resource source=disk',
                  );
                  return diskBytes;
                }
                await mediaCache.remove(diskKey);
              }
            } on Object catch (error) {
              debugPrint(
                '[LinkNest] 访客媒体磁盘缓存读取失败 '
                'id=$id resource=$resource reason=${error.runtimeType}',
              );
            }
          }
          final bytes = await loader(id);
          _ensureOpen();
          if ((_mediaCacheGenerations[id] ?? 0) == generation) {
            cache.put(id, bytes);
            if (mediaCache != null && diskKey != null) {
              try {
                await mediaCache.putBytes(diskKey, bytes);
              } on Object catch (error) {
                debugPrint(
                  '[LinkNest] 访客媒体磁盘缓存写入失败 '
                  'id=$id resource=$resource reason=${error.runtimeType}',
                );
              }
            }
          }
          debugPrint(
            '[LinkNest] 访客媒体读取完成 '
            'id=$id resource=$resource source=host',
          );
          return bytes;
        })
        .whenComplete(() {
          if (identical(inFlight[id], request)) inFlight.remove(id);
        });
    inFlight[id] = request;
    return request;
  }

  Future<void> _reconcileDiskCache(List<FileRecord> files) async {
    final mediaCache = _mediaCache;
    if (mediaCache == null) return;
    final valid = <String, Set<String>>{};
    for (final record in files) {
      valid[record.id] = {
        record.primaryResource.sha256,
        if (record.photoResource case final resource?) resource.sha256,
        if (record.pairedVideo case final resource?) resource.sha256,
      }..removeWhere((digest) => digest.isEmpty);
    }
    try {
      await mediaCache.reconcileSpace(_spaceId, valid);
    } on Object catch (error) {
      debugPrint('[LinkNest] 访客媒体缓存索引协调失败 reason=${error.runtimeType}');
    }
  }

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[bytes.length - 2] == 0xff &&
      bytes[bytes.length - 1] == 0xd9;

  void _invalidateMediaCache(String id, {required String reason}) {
    _mediaCacheGenerations[id] = (_mediaCacheGenerations[id] ?? 0) + 1;
    _thumbnailCache.remove(id);
    _previewCache.remove(id);
    _thumbnailRequests.remove(id);
    _previewRequests.remove(id);
    debugPrint('[LinkNest] 访客媒体缓存已失效 id=$id reason=$reason');
  }

  void _ensureOpen() {
    if (_closed) {
      throw const GuestApiException('DATA_SOURCE_CLOSED', '访客画廊连接已关闭。');
    }
  }

  static String _safeExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    final extension = name.substring(dot + 1);
    if (!RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(extension)) return '';
    return '.${extension.toLowerCase()}';
  }
}

class _ByteLruCache {
  _ByteLruCache({required this.maximumEntries, required this.maximumBytes});

  final int maximumEntries;
  final int maximumBytes;
  final LinkedHashMap<String, Uint8List> _values = LinkedHashMap();
  int _bytes = 0;

  Uint8List? get(String id) {
    final value = _values.remove(id);
    if (value != null) _values[id] = value;
    return value;
  }

  void put(String id, Uint8List value) {
    final previous = _values.remove(id);
    if (previous != null) _bytes -= previous.length;
    if (value.length > maximumBytes) return;
    _values[id] = value;
    _bytes += value.length;
    while (_values.length > maximumEntries || _bytes > maximumBytes) {
      final oldest = _values.keys.first;
      _bytes -= _values.remove(oldest)!.length;
    }
  }

  void retainIds(Set<String> ids) {
    final staleIds = _values.keys.where((id) => !ids.contains(id)).toList();
    for (final id in staleIds) {
      _bytes -= _values.remove(id)!.length;
    }
  }

  void remove(String id) {
    final value = _values.remove(id);
    if (value != null) _bytes -= value.length;
  }

  void clear() {
    _values.clear();
    _bytes = 0;
  }
}

class _AsyncRequestLimiter {
  _AsyncRequestLimiter(this.maximumConcurrent);

  final int maximumConcurrent;
  final Queue<Completer<void>> _waiters = Queue();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_active >= maximumConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await action();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
    }
  }
}
