import 'dart:io';

import 'package:flutter/foundation.dart';

import 'media_format.dart';
import 'server.dart';
import 'space_data_source.dart';

class HostDataSource implements SpaceDataSource, UploaderIdentityDataSource {
  HostDataSource(this._server, {required this.spaceName});

  final LinkNestServer _server;
  final List<PickedMedia> _pendingUploads = [];
  final Set<SpaceTransferCancellation> _activeTransfers = {};
  bool _closed = false;

  @override
  SpaceDataSourceCapabilities get capabilities =>
      SpaceDataSourceCapabilities.full;

  @override
  final ValueListenable<String> spaceName;

  @override
  final ValueNotifier<SpaceConnectionState> connectionState = ValueNotifier(
    SpaceConnectionState.connected,
  );

  @override
  final ValueNotifier<List<String>> pendingUploadNames = ValueNotifier(
    const [],
  );

  @override
  String get participantName => '发起者';

  @override
  String get uploaderId => _server.hostUploaderId;

  @override
  Future<List<FileRecord>> listFiles() async => _server.files;

  @override
  Future<Uint8List> thumbnail(String id) => _server.thumbnail(id);

  @override
  Future<Uint8List> preview(String id) => _server.preview(id);

  @override
  Future<AddFilesResult> addPickedMedia(
    List<PickedMedia> files, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) => _processPickedMedia(
    files,
    onProgress: onProgress,
    cancellation: cancellation,
  );

  @override
  Future<AddFilesResult> retryPendingUploads({
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    final pending = List<PickedMedia>.of(_pendingUploads);
    _pendingUploads.clear();
    _publishPendingUploads();
    return _processPickedMedia(
      pending,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<AddFilesResult> _processPickedMedia(
    List<PickedMedia> files, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    _ensureOpen();
    final transfer = cancellation ?? SpaceTransferCancellation();
    _activeTransfers.add(transfer);
    var added = 0;
    var skipped = 0;
    final unsupported = <String>[];
    final failed = <String>[];
    var cancelled = false;
    try {
      for (var index = 0; index < files.length; index++) {
        final picked = files[index];
        final source = File(picked.path);
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
          debugPrint('[LinkNest] 发起者跳过非图片或视频文件');
          await _deletePicked(picked);
          continue;
        }
        try {
          final total = await source.length();
          final pairedVideo = picked.isLivePhoto
              ? File(picked.pairedVideoPath)
              : null;
          final pairedSize = pairedVideo == null
              ? 0
              : await pairedVideo.length();
          onProgress?.call(
            SpaceTransferProgress(
              fileName: picked.name,
              completedBytes: 0,
              totalBytes: total + pairedSize,
            ),
          );
          final record = picked.isLivePhoto
              ? await _server.importLivePhoto(
                  source,
                  picked.name,
                  pairedVideo!,
                  picked.pairedVideoName,
                  participantName,
                  checkCancelled: transfer.throwIfCancelled,
                )
              : await _server.importFile(
                  source,
                  picked.name,
                  participantName,
                  checkCancelled: transfer.throwIfCancelled,
                );
          if (record == null) {
            skipped++;
          } else {
            added++;
          }
          onProgress?.call(
            SpaceTransferProgress(
              fileName: picked.name,
              completedBytes: total + pairedSize,
              totalBytes: total + pairedSize,
            ),
          );
        } on SpaceTransferCancelledException {
          cancelled = true;
          await _retainOrDelete(files.skip(index));
          break;
        } catch (error) {
          failed.add(picked.name);
          debugPrint('[LinkNest] 发起者添加媒体失败 reason=${error.runtimeType}');
          await _retainOrDelete([picked]);
        }
      }
    } finally {
      _activeTransfers.remove(transfer);
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
  Future<void> discardPendingUploads() async {
    final pending = List<PickedMedia>.of(_pendingUploads);
    _pendingUploads.clear();
    _publishPendingUploads();
    for (final picked in pending) {
      await _deletePicked(picked);
    }
  }

  @override
  Future<LocalOriginal> materializeOriginal(
    FileRecord record, {
    TransferProgressCallback? onProgress,
    SpaceTransferCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final file = File(_server.filePath(record.id));
    if (!await file.exists()) {
      throw FileSystemException('空间原文件不存在', file.path);
    }
    final paired = record.isLivePhoto
        ? File(_server.pairedVideoPath(record.id))
        : null;
    if (paired != null && !await paired.exists()) {
      throw FileSystemException('Live Photo 配对视频不存在', paired.path);
    }
    final size =
        await file.length() + (paired == null ? 0 : await paired.length());
    onProgress?.call(
      SpaceTransferProgress(
        fileName: record.name,
        completedBytes: size,
        totalBytes: size,
      ),
    );
    cancellation?.throwIfCancelled();
    return LocalOriginal(file.path, pairedVideoPath: paired?.path);
  }

  @override
  Future<void> reconnect() async {
    _ensureOpen();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final transfer in _activeTransfers.toList()) {
      transfer.cancel();
    }
    await discardPendingUploads();
    connectionState.value = const SpaceConnectionState(
      status: SpaceConnectionStatus.closed,
      message: '空间已关闭。',
    );
    connectionState.dispose();
    pendingUploadNames.dispose();
  }

  Future<void> _retainOrDelete(Iterable<PickedMedia> files) async {
    for (final picked in files) {
      if (_closed) {
        await _deletePicked(picked);
      } else if (await File(picked.path).exists() &&
          !_pendingUploads.any((item) => item.path == picked.path)) {
        _pendingUploads.add(picked);
      }
    }
    _publishPendingUploads();
  }

  Future<void> _deletePicked(PickedMedia picked) async {
    for (final path in [picked.path, picked.pairedVideoPath]) {
      if (path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        debugPrint(
          '[LinkNest] 清理发起者选择器缓存失败 '
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

  void _ensureOpen() {
    if (_closed) throw StateError('Host 数据源已关闭。');
  }
}
