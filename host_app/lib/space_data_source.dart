import 'dart:async';

import 'package:flutter/foundation.dart';

import 'file_record.dart';

typedef TransferProgressCallback = void Function(
  SpaceTransferProgress progress,
);

enum SpaceConnectionStatus {
  connected,
  degraded,
  disconnected,
  incompatible,
  closed,
}

class SpaceConnectionState {
  const SpaceConnectionState({
    required this.status,
    required this.message,
    this.consecutiveFailures = 0,
  });

  static const connected = SpaceConnectionState(
    status: SpaceConnectionStatus.connected,
    message: '',
  );

  final SpaceConnectionStatus status;
  final String message;
  final int consecutiveFailures;

  bool get canReconnect =>
      status == SpaceConnectionStatus.degraded ||
      status == SpaceConnectionStatus.disconnected;
}

class SpaceTransferCancelledException implements Exception {
  const SpaceTransferCancelledException();

  @override
  String toString() => '操作已取消。';
}

class SpaceTransferCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const SpaceTransferCancelledException();
  }
}

class SpaceDataSourceCapabilities {
  const SpaceDataSourceCapabilities({
    required this.canAddMedia,
    required this.canSaveOriginals,
  });

  static const full = SpaceDataSourceCapabilities(
    canAddMedia: true,
    canSaveOriginals: true,
  );

  static const readOnly = SpaceDataSourceCapabilities(
    canAddMedia: false,
    canSaveOriginals: false,
  );

  static const uploadEnabled = SpaceDataSourceCapabilities(
    canAddMedia: true,
    canSaveOriginals: false,
  );

  final bool canAddMedia;
  final bool canSaveOriginals;
}

abstract interface class GuestLifecycleDataSource {
  bool consumeBackgroundInterruptedUpload();
}

/// 原生选择器复制到应用缓存的媒体文件。
///
/// 传给 [SpaceDataSource.addPickedMedia] 后，数据源取得该缓存文件的所有权：
/// Host 会把它移入空间，Guest 会在上传成功或重复后删除它；失败或取消项
/// 保留到重试、放弃或数据源关闭。
class PickedMedia {
  const PickedMedia({
    required this.path,
    required this.name,
    this.pairedVideoPath = '',
    this.pairedVideoName = '',
  });

  factory PickedMedia.fromMap(Map<String, String> value) => PickedMedia(
    path: value['path'] ?? '',
    name: value['name'] ?? '未知',
    pairedVideoPath: value['pairedVideoPath'] ?? '',
    pairedVideoName: value['pairedVideoName'] ?? '',
  );

  final String path;
  final String name;
  final String pairedVideoPath;
  final String pairedVideoName;

  bool get isLivePhoto => pairedVideoPath.isNotEmpty;
}

class SpaceTransferProgress {
  const SpaceTransferProgress({
    required this.fileName,
    required this.completedBytes,
    required this.totalBytes,
  });

  final String fileName;
  final int completedBytes;
  final int totalBytes;
}

class AddFilesResult {
  const AddFilesResult({
    required this.added,
    required this.skipped,
    this.unsupported = const [],
    this.failed = const [],
    this.pending = 0,
    this.cancelled = false,
  });

  final int added;
  final int skipped;
  final List<String> unsupported;
  final List<String> failed;
  final int pending;
  final bool cancelled;
}

/// 可供原生相册保存的本地原文件。
///
/// Host 返回空间中的现有文件，清理函数为空；Guest 后续会返回下载到缓存的
/// 临时文件，并通过 [dispose] 删除。
class LocalOriginal {
  LocalOriginal(this.path, {this.pairedVideoPath, this.onDispose});

  final String path;
  final String? pairedVideoPath;
  final FutureOr<void> Function()? onDispose;
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final callback = onDispose;
    if (callback != null) await callback();
  }
}

class NetworkVideoPlaybackSource {
  const NetworkVideoPlaybackSource({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;
}

abstract interface class NetworkVideoDataSource {
  NetworkVideoPlaybackSource? videoPlaybackSource(FileRecord record);
}

/// Host 与 Guest 画廊共用的数据边界。
///
/// UI 只表达“列文件、取预览、添加媒体、取得原文件”等用户意图，不感知
/// 数据来自本机 LinkNestServer 还是局域网 HTTP API。
abstract interface class SpaceDataSource {
  SpaceDataSourceCapabilities get capabilities;

  ValueListenable<String> get spaceName;

  ValueListenable<SpaceConnectionState> get connectionState;

  ValueListenable<List<String>> get pendingUploadNames;

  String get participantName;

  Future<List<FileRecord>> listFiles();

  Future<Uint8List> thumbnail(String id);

  Future<Uint8List> preview(String id);

  Future<AddFilesResult> addPickedMedia(
    List<PickedMedia> files, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  });

  Future<AddFilesResult> retryPendingUploads({
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  });

  Future<void> discardPendingUploads();

  Future<LocalOriginal> materializeOriginal(
    FileRecord record, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  });

  Future<void> reconnect();

  Future<void> close();
}

/// 旧版数据源没有归属能力时，画廊不根据昵称推断自己。
abstract interface class UploaderIdentityDataSource {
  String get uploaderId;
}
