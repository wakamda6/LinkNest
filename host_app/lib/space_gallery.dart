import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_ui.dart';
import 'app_theme.dart';
import 'file_record.dart';
import 'media_format.dart';
import 'native.dart';
import 'space_data_source.dart';

typedef NetworkVideoControllerFactory = VideoPlayerController Function(
  NetworkVideoPlaybackSource source,
);

typedef LocalVideoControllerFactory = VideoPlayerController Function(File file);

VideoPlayerController _createNetworkVideoController(
  NetworkVideoPlaybackSource source,
) => VideoPlayerController.networkUrl(source.uri, httpHeaders: source.headers);

VideoPlayerController _createLocalVideoController(File file) =>
    VideoPlayerController.file(file);

Future<LocalOriginal> _prepareLocalVideoForPlayback(
  SpaceDataSource dataSource,
  FileRecord record,
) async {
  final original = await dataSource.materializeOriginal(record);
  if (!Platform.isIOS) return original;
  try {
    final dot = record.name.lastIndexOf('.');
    if (dot < 0 || dot == record.name.length - 1) {
      throw const FormatException('视频文件缺少扩展名');
    }
    final extension = record.name.substring(dot + 1).toLowerCase();
    final playbackPath = await LinkNestNative().prepareLocalVideoPlayback(
      original.path,
      extension,
    );
    return LocalOriginal(
      playbackPath,
      onDispose: () async {
        try {
          final playbackFile = File(playbackPath);
          if (await playbackFile.exists()) await playbackFile.delete();
        } finally {
          await original.dispose();
        }
      },
    );
  } catch (_) {
    await original.dispose();
    rethrow;
  }
}

NetworkVideoPlaybackSource? _resolveNetworkVideoSource(
  SpaceDataSource dataSource,
  FileRecord file,
) {
  if (dataSource case final NetworkVideoDataSource networkDataSource) {
    return networkDataSource.videoPlaybackSource(file);
  }
  return null;
}

bool _canSaveRecord(FileRecord record) =>
    record.isLivePhoto || MediaFormats.ofName(record.name).isAcceptedMedia;

String _viewerHeroTag(FileRecord record) => 'linknest-viewer-${record.id}';

const _galleryHeadingFont = 'LinkNestLora';
const _galleryBodyFont = 'LinkNestRaleway';

String _saveActionLabel(FileRecord record) {
  if (record.isLivePhoto) {
    return Platform.isIOS ? '保存到相册' : '保存原文件';
  }
  return MediaFormats.ofName(record.name).savesToFiles ? '保存到文件' : '保存到相册';
}

String _saveResultMessage(FileRecord record, NativeSaveResult result) {
  if (result.succeeded) {
    if (record.isLivePhoto && Platform.isAndroid) {
      return '已将 2 个 Live Photo 原始文件保存到 Downloads/LinkNest';
    }
    return _saveActionLabel(record) == '保存到文件'
        ? (Platform.isAndroid ? '已保存到 Downloads/LinkNest' : '已保存到“文件”')
        : '已保存到相册';
  }
  if (result.cancelled) return '已取消保存';
  if (result.status == NativeSaveStatus.permissionDenied) {
    return result.message.isEmpty ? '没有保存权限' : result.message;
  }
  return result.message.isEmpty ? '保存失败' : '保存失败：${result.message}';
}

Future<NativeSaveResult> _saveOriginal({
  required SpaceDataSource dataSource,
  required LinkNestNative native,
  required FileRecord record,
  SpaceTransferCancellation? cancellation,
  TransferProgressCallback? onProgress,
}) async {
  if (!_canSaveRecord(record)) {
    return const NativeSaveResult(
      status: NativeSaveStatus.unsupported,
      message: '该文件不是 LinkNest 支持的图片或视频',
    );
  }
  LocalOriginal? original;
  try {
    original = await dataSource.materializeOriginal(
      record,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    cancellation?.throwIfCancelled();
    if (record.isLivePhoto) {
      final pairedPath = original.pairedVideoPath;
      if (pairedPath == null) {
        return const NativeSaveResult(
          status: NativeSaveStatus.failed,
          message: 'Live Photo 配对视频缺失',
        );
      }
      return await native.saveLivePhoto(
        photoPath: original.path,
        photoName: record.photoResource!.name,
        pairedVideoPath: pairedPath,
        pairedVideoName: record.pairedVideo!.name,
      );
    }
    final format = MediaFormats.ofName(record.name);
    final file = NativeSaveFile(
      path: original.path,
      name: record.name,
      mimeType: record.mimeType,
    );
    if (format.savesToFiles) return await native.saveToFiles([file]);
    final albumResult = await native.saveToAlbum(
      original.path,
      record.name,
      kind: record.kind,
      mimeType: record.mimeType,
    );
    if (format.supportLevel == MediaSupportLevel.basic &&
        !albumResult.succeeded &&
        !albumResult.cancelled) {
      debugPrint(
        '[LinkNest] 相册未返回可用媒体，改用文件选择器 '
        'name=${record.name} status=${albumResult.status.name}',
      );
      return await native.saveToFiles([file]);
    }
    return albumResult;
  } finally {
    await original?.dispose();
  }
}

class SpaceGalleryScreen extends StatefulWidget {
  const SpaceGalleryScreen({
    super.key,
    required this.dataSource,
    required this.native,
    this.header,
    this.closeDataSourceOnDispose = true,
    this.automaticallyImplyLeading = true,
    this.guestMode = false,
    this.exitAction,
    this.statusLine,
    this.videoControllerFactory,
    this.localVideoControllerFactory,
  });

  final SpaceDataSource dataSource;
  final LinkNestNative native;
  final Widget? header;
  final bool closeDataSourceOnDispose;
  final bool automaticallyImplyLeading;
  final bool guestMode;
  final Widget? exitAction;
  final Widget? statusLine;
  final NetworkVideoControllerFactory? videoControllerFactory;
  final LocalVideoControllerFactory? localVideoControllerFactory;

  @override
  State<SpaceGalleryScreen> createState() => _SpaceGalleryScreenState();
}

class _SpaceGalleryScreenState extends State<SpaceGalleryScreen>
    with WidgetsBindingObserver {
  List<FileRecord> _files = const [];
  final Set<String> _selected = {};
  Timer? _refreshTimer;
  String _sort = 'newest';
  int _grid = 3;
  String _mode = 'default';
  String? _activeUploader;
  bool _selecting = false;
  bool _savingBatch = false;
  bool _adding = false;
  bool _refreshing = false;
  bool _initialLoading = true;
  bool _reconnecting = false;
  bool _discardingPending = false;
  bool _guestExitApproved = false;
  bool _guestExitPromptOpen = false;
  bool _guestWasBackgrounded = false;
  bool _guestResumeInFlight = false;
  bool _retryInterruptedUploadWhenIdle = false;
  String? _loadError;
  String _displayedUploaderId = '';
  String _displayedParticipantName = '';
  String? _guestLifecycleNotice;
  SpaceTransferProgress? _transferProgress;
  SpaceTransferCancellation? _activeTransfer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.dataSource.connectionState.addListener(_scheduleRefresh);
    unawaited(_refreshFiles());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.guestMode) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_guestWasBackgrounded) return;
      _guestWasBackgrounded = true;
      _refreshTimer?.cancel();
      debugPrint('[LinkNest] 访客画廊进入后台');
      return;
    }
    if (state == AppLifecycleState.resumed && _guestWasBackgrounded) {
      _guestWasBackgrounded = false;
      debugPrint('[LinkNest] 访客画廊恢复到前台');
      unawaited(_resumeGuestSession());
    }
  }

  @override
  void didUpdateWidget(covariant SpaceGalleryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.dataSource, widget.dataSource)) {
      oldWidget.dataSource.connectionState.removeListener(_scheduleRefresh);
      widget.dataSource.connectionState.addListener(_scheduleRefresh);
      if (oldWidget.closeDataSourceOnDispose) {
        unawaited(oldWidget.dataSource.close());
      }
      _files = const [];
      _selected.clear();
      _selecting = false;
      _mode = 'default';
      _activeUploader = null;
      _initialLoading = true;
      _loadError = null;
      _activeTransfer?.cancel();
      _activeTransfer = null;
      unawaited(_refreshFiles());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _activeTransfer?.cancel();
    widget.dataSource.connectionState.removeListener(_scheduleRefresh);
    if (widget.closeDataSourceOnDispose) {
      unawaited(widget.dataSource.close());
    }
    super.dispose();
  }

  Future<void> _refreshFiles() async {
    _refreshTimer?.cancel();
    if (_guestWasBackgrounded) return;
    if (_refreshing) {
      _scheduleRefresh();
      return;
    }
    _refreshing = true;
    try {
      final files = await widget.dataSource.listFiles();
      if (!mounted) return;
      final reconciled = _reconcileFiles(files);
      final changed = !_sameFileInstances(_files, reconciled);
      final uploaderId = _myUploaderId;
      final identityChanged =
          _displayedUploaderId != uploaderId ||
          _displayedParticipantName != widget.dataSource.participantName;
      if (!changed &&
          !identityChanged &&
          !_initialLoading &&
          _loadError == null) {
        return;
      }
      if (changed || identityChanged) {
        debugPrint(
          '[LinkNest] 画廊上传归属已更新 '
          'total=${reconciled.length} own=${reconciled.where((file) => uploaderId.isNotEmpty && file.uploaderId == uploaderId).length}',
        );
      }
      setState(() {
        _files = reconciled;
        _displayedUploaderId = uploaderId;
        _displayedParticipantName = widget.dataSource.participantName;
        _loadError = null;
        _initialLoading = false;
        _selected.removeWhere(
          (id) => !reconciled.any((record) => record.id == id),
        );
      });
    } catch (e) {
      debugPrint('[LinkNest] 刷新画廊失败 reason=${e.runtimeType}');
      if (!mounted) return;
      setState(() {
        _loadError =
            widget.dataSource.connectionState.value.status ==
                SpaceConnectionStatus.connected
            ? '刷新失败：$e'
            : null;
        _initialLoading = false;
      });
    } finally {
      _refreshing = false;
      _scheduleRefresh();
    }
  }

  List<FileRecord> _reconcileFiles(List<FileRecord> incoming) {
    final previousById = {for (final file in _files) file.id: file};
    var reused = 0;
    final result = incoming
        .map((file) {
          final previous = previousById[file.id];
          if (previous != null && previous.hasSamePresentationAs(file)) {
            reused++;
            return previous;
          }
          return file;
        })
        .toList(growable: false);
    if (_files.isNotEmpty && reused != result.length) {
      debugPrint(
        '[LinkNest] 画廊文件列表已更新 total=${result.length} '
        'reused=$reused',
      );
    }
    return result;
  }

  bool _sameFileInstances(List<FileRecord> left, List<FileRecord> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!identical(left[index], right[index])) return false;
    }
    return true;
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    if (!mounted || _guestWasBackgrounded) return;
    final status = widget.dataSource.connectionState.value.status;
    final delay = switch (status) {
      SpaceConnectionStatus.connected => const Duration(seconds: 3),
      SpaceConnectionStatus.degraded => const Duration(seconds: 5),
      SpaceConnectionStatus.disconnected => const Duration(seconds: 10),
      SpaceConnectionStatus.incompatible ||
      SpaceConnectionStatus.closed => null,
    };
    if (delay == null) return;
    _refreshTimer = Timer(delay, () => unawaited(_refreshFiles()));
  }

  Future<void> _requestGuestExit() async {
    if (!widget.guestMode || _guestExitPromptOpen) return;
    _guestExitPromptOpen = true;
    final confirmed = await showLinkNestDialog<bool>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '退出空间？',
        actions: [
          LinkNestButton(
            onPressed: () => popLinkNest(context, false),
            label: '取消',
            variant: FButtonVariant.secondary,
          ),
          LinkNestButton(
            onPressed: () => popLinkNest(context, true),
            label: '退出空间',
            variant: FButtonVariant.destructive,
          ),
        ],
        child: const Text('退出后将断开与 Host 的连接，正在进行或等待重试的上传会被取消。'),
      ),
    );
    _guestExitPromptOpen = false;
    if (confirmed != true || !mounted) return;
    debugPrint('[LinkNest] 访客已确认退出空间');
    setState(() => _guestExitApproved = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) popLinkNest(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      backgroundColor: context.theme.colors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.44,
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            _buildGalleryHeader(),
                            if (widget.header != null) widget.header!,
                            if (_transferProgress != null)
                              _TransferProgressBar(
                                progress: _transferProgress!,
                                onCancel: _activeTransfer?.cancel,
                              ),
                            ValueListenableBuilder<SpaceConnectionState>(
                              valueListenable:
                                  widget.dataSource.connectionState,
                              builder: (context, state, _) => _ConnectionBanner(
                                state: state,
                                reconnecting: _reconnecting,
                                onReconnect: state.canReconnect
                                    ? _reconnect
                                    : null,
                                onLeave:
                                    state.status ==
                                            SpaceConnectionStatus
                                                .disconnected ||
                                        state.status ==
                                            SpaceConnectionStatus.incompatible
                                    ? () => maybePopLinkNest(context)
                                    : null,
                              ),
                            ),
                            if (_guestLifecycleNotice != null)
                              Container(
                                width: double.infinity,
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(_guestLifecycleNotice!),
                                    ),
                                  ],
                                ),
                              ),
                            ValueListenableBuilder<List<String>>(
                              valueListenable:
                                  widget.dataSource.pendingUploadNames,
                              builder: (context, pending, _) =>
                                  _PendingUploadBanner(
                                    names: pending,
                                    busy:
                                        _adding ||
                                        _activeTransfer != null ||
                                        _discardingPending,
                                    onRetry: _retryPendingUploads,
                                    onDiscard: _discardPendingUploads,
                                  ),
                            ),
                            if (_loadError != null)
                              LinkNestNotice(
                                message: _loadError!,
                                error: true,
                                actions: [
                                  LinkNestAction(
                                    onPressed: _refreshing
                                        ? null
                                        : _refreshFiles,
                                    label: '重试',
                                  ),
                                ],
                              ),

                            if (_mode != 'default' && _activeUploader != null)
                              _buildUploaderBar(),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: _mode == 'default' || _activeUploader != null
                          ? _buildGallery()
                          : _buildUploaderGroups(),
                    ),
                  ],
                ),
              ),
            ),
            if (_selecting) _buildSelectionBar(),
          ],
        ),
      ),
    );
    if (!widget.guestMode) return scaffold;
    return PopScope<void>(
      canPop: _guestExitApproved,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestGuestExit());
      },
      child: scaffold,
    );
  }

  Widget _buildGalleryHeader() {
    return Padding(
      key: const ValueKey('gallery-header'),
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        children: [
          Padding(
            key: const ValueKey('gallery-title-row'),
            padding: const EdgeInsets.only(
              left: 25,
              right: 25,
              top: 4,
              bottom: 4,
            ),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ValueListenableBuilder<String>(
                        valueListenable: widget.dataSource.spaceName,
                        builder: (context, name, _) => Text(
                          name.isEmpty ? '空间' : name,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: context.theme.typography.body.lg.copyWith(
                            fontSize: 20,
                            fontFamily: _galleryHeadingFont,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.dataSource.participantName,
                          maxLines: 1,
                          softWrap: false,
                          style: context.theme.typography.body.sm.copyWith(
                            color: context.theme.colors.mutedForeground,
                            fontFamily: _galleryBodyFont,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            key: const ValueKey('gallery-identity-row'),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                widget.exitAction ??
                    (widget.guestMode
                        ? FButton.icon(
                            key: const ValueKey('guest-exit'),
                            variant: FButtonVariant.ghost,
                            semanticsLabel: '退出空间',
                            semanticsTooltip: '退出空间',
                            onPress: _requestGuestExit,
                            child: const Icon(FLucideIcons.logOut, size: 22),
                          )
                        : widget.automaticallyImplyLeading &&
                              Navigator.of(context).canPop()
                        ? FButton.icon(
                            variant: FButtonVariant.ghost,
                            semanticsLabel: '返回',
                            onPress: () => maybePopLinkNest(context),
                            child: const Icon(FLucideIcons.chevronLeft),
                          )
                        : const SizedBox.shrink()),
                const Spacer(),
                if (widget.statusLine != null) ...[
                  widget.statusLine!,
                  const SizedBox(width: 8),
                ],
                if (widget.dataSource.capabilities.canAddMedia) ...[
                  FButton.icon(
                    key: const ValueKey('gallery-upload'),
                    variant: FButtonVariant.ghost,
                    semanticsLabel: '添加图片',
                    semanticsTooltip: '添加图片',
                    onPress: _adding || _activeTransfer != null
                        ? null
                        : _pickAndAdd,
                    child: const Icon(FLucideIcons.imagePlus, size: 22),
                  ),
                  const SizedBox(width: 8),
                ],
                _buildGalleryActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploaderBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          LinkNestAction(
            onPressed: () => setState(() => _activeUploader = null),
            label: '返回',
            icon: FLucideIcons.chevronLeft,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _activeUploaderName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploaderGroups() {
    final groups = _groupedFiles();
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (groups.isEmpty) {
      return _EmptyGallery(
        canAddMedia: widget.dataSource.capabilities.canAddMedia,
      );
    }
    return _ownershipGrid<_UploaderGroup>(
      storageKey: 'gallery-uploaders',
      items: groups,
      isMine: (group) => _isMine(group.cover),
      aspectRatio: 0.8,
      itemBuilder: (context, index) {
        final group = groups[index];
        return GestureDetector(
          key: ValueKey(group.key),
          onTap: () => setState(() => _activeUploader = group.key),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _PreviewImage(
                        dataSource: widget.dataSource,
                        file: group.cover,
                        showBadge: false,
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '${group.count}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  String get _myUploaderId => switch (widget.dataSource) {
    UploaderIdentityDataSource source => source.uploaderId,
    _ => '',
  };

  bool _isMine(FileRecord file) =>
      _displayedUploaderId.isNotEmpty &&
      file.uploaderId == _displayedUploaderId;

  String _uploaderKey(FileRecord file) => file.uploaderId.isEmpty
      ? 'legacy:${file.uploader}'
      : 'id:${file.uploaderId}';

  String get _activeUploaderName {
    for (final file in _files) {
      if (_uploaderKey(file) == _activeUploader) return file.uploader;
    }
    return '';
  }

  int _compareTime(FileRecord a, FileRecord b) {
    final order = _sort == 'oldest'
        ? a.uploadedAt.compareTo(b.uploadedAt)
        : b.uploadedAt.compareTo(a.uploadedAt);
    return order != 0 ? order : a.id.compareTo(b.id);
  }

  List<_UploaderGroup> _groupedFiles() {
    final grouped = <String, List<FileRecord>>{};
    for (final file in _files) {
      grouped.putIfAbsent(_uploaderKey(file), () => []).add(file);
    }
    return grouped.entries.map((entry) {
      final records = entry.value..sort(_compareTime);
      return _UploaderGroup(
        entry.key,
        records.first.uploader,
        records.length,
        records.first,
      );
    }).toList()..sort((a, b) {
      if (_isMine(a.cover) != _isMine(b.cover)) {
        return _isMine(a.cover) ? 1 : -1;
      }
      return _compareTime(a.cover, b.cover);
    });
  }

  List<FileRecord> _sortedFiles() {
    final visible = _activeUploader == null
        ? _files
        : _files
              .where((file) => _uploaderKey(file) == _activeUploader)
              .toList();
    return [...visible]..sort((a, b) {
      if (_isMine(a) != _isMine(b)) return _isMine(a) ? 1 : -1;
      return _compareTime(a, b);
    });
  }

  /// 两段网格共用一个滚动视图，不插入假文件，保存和大图索引仍使用原文件列表。
  Widget _ownershipGrid<T>({
    required String storageKey,
    required List<T> items,
    required bool Function(T) isMine,
    required Widget Function(BuildContext, int) itemBuilder,
    double aspectRatio = 1,
  }) {
    final boundary = items.indexWhere(isMine);
    final divided = boundary > 0;
    Widget grid(int start, int end) => SliverPadding(
      padding: const EdgeInsets.all(12),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _grid,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: aspectRatio,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => itemBuilder(context, start + index),
          childCount: end - start,
        ),
      ),
    );
    return CustomScrollView(
      key: PageStorageKey(storageKey),
      slivers: [
        if (!divided)
          grid(0, items.length)
        else ...[
          grid(0, boundary),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Divider(
                      color: context.theme.colors.border.withValues(alpha: 0.5),
                      thickness: 0.5,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '我上传的',
                      style: context.theme.typography.body.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Divider(
                      color: context.theme.colors.border.withValues(alpha: 0.5),
                      thickness: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          grid(boundary, items.length),
        ],
      ],
    );
  }

  Widget _buildGalleryActions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FButton.icon(
        key: const ValueKey('gallery-options'),
        variant: FButtonVariant.ghost,
        semanticsLabel: '排序与显示选项',
        semanticsTooltip: '排序与显示选项',
        onPress: _openGalleryOptions,
        child: const Icon(FLucideIcons.slidersHorizontal, size: 20),
      ),
      if (widget.dataSource.capabilities.canSaveOriginals) ...[
        const SizedBox(width: 8),
        FButton.icon(
          key: const ValueKey('gallery-multiselect'),
          variant: _selecting ? FButtonVariant.secondary : FButtonVariant.ghost,
          semanticsLabel: '多选',
          semanticsTooltip: '多选',
          onPress: () => setState(() {
            _selecting = !_selecting;
            _selected.clear();
          }),
          child: const Icon(FLucideIcons.listChecks, size: 20),
        ),
      ],
    ],
  );

  Future<void> _openGalleryOptions() async {
    debugPrint('[LinkNest] 打开画廊显示选项');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.theme.colors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, updateSheet) {
          Widget choices<T>(
            String title,
            Map<T, String> options,
            T selected,
            void Function(T) onSelected,
          ) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: sheetContext.theme.typography.body.sm.copyWith(
                    color: sheetContext.theme.colors.mutedForeground,
                    fontFamily: _galleryBodyFont,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in options.entries)
                      Semantics(
                        selected: selected == option.key,
                        child: FButton(
                          variant: selected == option.key
                              ? FButtonVariant.secondary
                              : FButtonVariant.ghost,
                          mainAxisSize: MainAxisSize.min,
                          onPress: () {
                            onSelected(option.key);
                            updateSheet(() {});
                          },
                          child: Text(
                            option.value,
                            style: const TextStyle(
                              fontFamily: _galleryBodyFont,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );

          final mode = themeModeNotifier.value;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              16 + MediaQuery.viewPaddingOf(sheetContext).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '画廊显示',
                          style: sheetContext.theme.typography.body.lg.copyWith(
                            fontFamily: _galleryHeadingFont,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      FButton.icon(
                        variant: FButtonVariant.ghost,
                        semanticsLabel: '关闭画廊选项',
                        onPress: () => Navigator.of(sheetContext).pop(),
                        child: const Icon(FLucideIcons.x),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  choices(
                    '分组',
                    const {'default': '全部照片', 'uploader': '上传者'},
                    _mode,
                    (value) {
                      debugPrint('[LinkNest] 切换画廊分组 mode=$value');
                      setState(() {
                        _mode = value;
                        if (value == 'uploader') _activeUploader = null;
                      });
                    },
                  ),
                  choices(
                    '排序',
                    const {'newest': '最新优先', 'oldest': '最旧优先'},
                    _sort,
                    (value) {
                      debugPrint('[LinkNest] 切换画廊排序 order=$value');
                      setState(() => _sort = value);
                    },
                  ),
                  choices('网格大小', const {2: '大', 3: '中', 4: '小'}, _grid, (
                    value,
                  ) {
                    debugPrint('[LinkNest] 切换画廊网格 columns=$value');
                    setState(() => _grid = value);
                  }),
                  choices(
                    '外观',
                    const {
                      ThemeMode.light: '浅色',
                      ThemeMode.dark: '深色',
                      ThemeMode.system: '跟随系统',
                    },
                    mode,
                    (value) {
                      themeModeNotifier.value = value;
                      updateSheet(() {});
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGallery() {
    final sorted = _sortedFiles();
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sorted.isEmpty) {
      return _EmptyGallery(
        canAddMedia: widget.dataSource.capabilities.canAddMedia,
      );
    }
    return _ownershipGrid<FileRecord>(
      storageKey: 'gallery-files',
      items: sorted,
      isMine: _isMine,
      itemBuilder: (context, index) {
        final file = sorted[index];
        Widget preview = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _PreviewImage(dataSource: widget.dataSource, file: file),
        );
        if (file.kind == 'image' && !file.isLivePhoto) {
          preview = Hero(tag: _viewerHeroTag(file), child: preview);
        }
        return Semantics(
          label:
              '${file.isLivePhoto
                  ? 'Live Photo'
                  : file.kind == 'video'
                  ? '视频'
                  : '图片'}，${file.name}',
          button: true,
          selected: _selecting && _selected.contains(file.id),
          child: GestureDetector(
            key: ValueKey(file.id),
            onTap: () => _selecting ? _toggleSelect(file) : _openViewer(file),
            child: Stack(
              fit: StackFit.expand,
              children: [
                preview,
                if (_selecting)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: _selected.contains(file.id)
                        ? CircleAvatar(
                            radius: 10,
                            backgroundColor: context.theme.colors.primary,
                            child: Icon(
                              FLucideIcons.check,
                              size: 14,
                              color: context.theme.colors.primaryForeground,
                            ),
                          )
                        : Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              color: Colors.black38,
                            ),
                          ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openViewer(FileRecord file) {
    final sorted = _sortedFiles();
    final index = sorted.indexWhere((record) => record.id == file.id);
    final useImageHero =
        file.kind == 'image' &&
        !file.isLivePhoto &&
        !LinkNestMotion.reduced(context);
    pushLinkNestRoute(
      context,
      PageRouteBuilder<void>(
        opaque: !useImageHero,
        barrierColor: useImageHero ? null : Colors.black,
        transitionDuration: LinkNestMotion.duration(
          context,
          LinkNestMotion.enter,
        ),
        reverseTransitionDuration: LinkNestMotion.duration(
          context,
          LinkNestMotion.exit,
        ),
        pageBuilder: (_, animation, secondaryAnimation) => _ViewerScreen(
          dataSource: widget.dataSource,
          native: widget.native,
          files: sorted,
          initialIndex: index < 0 ? 0 : index,
          guestMode: widget.guestMode,
          videoControllerFactory: widget.videoControllerFactory,
          localVideoControllerFactory: widget.localVideoControllerFactory,
        ),
        transitionsBuilder: (_, animation, secondaryAnimation, child) {
          if (useImageHero) return child;
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  void _toggleSelect(FileRecord file) {
    setState(() {
      if (!_selected.remove(file.id)) _selected.add(file.id);
    });
  }

  Widget _buildSelectionBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '已选 ${_selected.length} 个',
            style: context.theme.typography.body.sm,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              LinkNestAction(
                label: '取消',
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LinkNestButton(
                  label: _savingBatch ? '正在保存…' : '保存到本机',
                  busy: _savingBatch,
                  onPressed:
                      _selected.isEmpty ||
                          _savingBatch ||
                          _activeTransfer != null
                      ? null
                      : _saveSelected,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveSelected() async {
    if (_savingBatch || _activeTransfer != null) return;
    final selected = _selected.toList();
    debugPrint('[LinkNest] 开始保存所选文件 count=${selected.length}');
    final transfer = SpaceTransferCancellation();
    setState(() {
      _savingBatch = true;
      _activeTransfer = transfer;
    });
    var succeeded = 0;
    final failed = <String>{};
    var cancelled = false;
    for (var index = 0; index < selected.length; index++) {
      final id = selected[index];
      if (transfer.isCancelled) {
        cancelled = true;
        failed.addAll(selected.skip(index));
        break;
      }
      FileRecord? record;
      for (final file in _files) {
        if (file.id == id) {
          record = file;
          break;
        }
      }
      if (record == null) continue;
      try {
        final result = await _saveRecord(record, cancellation: transfer);
        if (result.cancelled) {
          cancelled = true;
          failed.addAll(selected.skip(index));
          break;
        }
        if (result.succeeded) {
          succeeded++;
        } else {
          failed.add(id);
          debugPrint(
            '[LinkNest] 保存所选文件被拒绝 id=$id '
            'status=${result.status.name} message=${result.message}',
          );
        }
      } on SpaceTransferCancelledException {
        cancelled = true;
        failed.addAll(selected.skip(index));
        break;
      } catch (e) {
        failed.add(id);
        debugPrint('[LinkNest] 保存所选文件失败 id=$id reason=${e.runtimeType}');
      }
    }
    if (!mounted) return;
    debugPrint(
      '[LinkNest] 批量保存结束 succeeded=$succeeded failed=${failed.length} '
      'cancelled=$cancelled',
    );
    _snack(
      cancelled
          ? '已取消保存；成功 $succeeded 个，${failed.length} 个仍保持选中'
          : '保存完成：成功 $succeeded 个，失败 ${failed.length} 个',
    );
    setState(() {
      _savingBatch = false;
      _transferProgress = null;
      if (identical(_activeTransfer, transfer)) _activeTransfer = null;
      _selected
        ..clear()
        ..addAll(failed);
      if (failed.isEmpty) _selecting = false;
    });
  }

  Future<NativeSaveResult> _saveRecord(
    FileRecord record, {
    SpaceTransferCancellation? cancellation,
  }) => _saveOriginal(
    dataSource: widget.dataSource,
    native: widget.native,
    record: record,
    cancellation: cancellation,
    onProgress: _onTransferProgress,
  );

  Future<void> _pickAndAdd() async {
    if (_adding || _activeTransfer != null) return;
    setState(() => _adding = true);
    try {
      final values = await widget.native.pickFromAlbum();
      final picked = values
          .map(PickedMedia.fromMap)
          .where((file) => file.path.isNotEmpty)
          .toList();
      debugPrint(
        '[LinkNest] 相册选择完成 count=${picked.length} '
        'livePhoto=${picked.where((file) => file.isLivePhoto).length}',
      );
      if (picked.isEmpty) return;
      await _runUpload(
        (transfer) => widget.dataSource.addPickedMedia(
          picked,
          onProgress: _onTransferProgress,
          cancellation: transfer,
        ),
      );
    } catch (e) {
      debugPrint('[LinkNest] 添加所选媒体失败 reason=${e.runtimeType}');
      if (mounted) _snack('添加失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _adding = false;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _retryPendingUploads() async {
    if (_adding || _activeTransfer != null) return;
    setState(() => _adding = true);
    try {
      await _runUpload(
        (transfer) => widget.dataSource.retryPendingUploads(
          onProgress: _onTransferProgress,
          cancellation: transfer,
        ),
      );
    } catch (e) {
      debugPrint('[LinkNest] 重试待上传文件失败 reason=${e.runtimeType}');
      if (mounted) _snack('重试失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _adding = false;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _runUpload(
    Future<AddFilesResult> Function(SpaceTransferCancellation transfer) run,
  ) async {
    final transfer = SpaceTransferCancellation();
    setState(() => _activeTransfer = transfer);
    debugPrint('[LinkNest] 开始上传媒体');
    try {
      final result = await run(transfer);
      debugPrint(
        '[LinkNest] 上传处理结束 added=${result.added} skipped=${result.skipped} '
        'pending=${result.pending} failed=${result.failed.length} '
        'cancelled=${result.cancelled}',
      );
      await _refreshFiles();
      if (!mounted) return;
      final parts = <String>[];
      if (result.cancelled) parts.add('已取消上传');
      if (result.added > 0) parts.add('添加 ${result.added} 个');
      if (result.skipped > 0) parts.add('跳过 ${result.skipped} 个重复');
      if (result.unsupported.isNotEmpty) {
        parts.add('跳过 ${result.unsupported.length} 个非图片或视频文件');
      }
      if (result.pending > 0) parts.add('${result.pending} 个等待重试');
      if (result.failed.isNotEmpty && result.pending == 0) {
        parts.add('${result.failed.length} 个失败');
      }
      _snack(parts.join('，').isEmpty ? '没有文件被上传' : parts.join('，'));
    } finally {
      if (mounted && identical(_activeTransfer, transfer)) {
        setState(() => _activeTransfer = null);
        _tryRetryInterruptedUpload();
      }
    }
  }

  Future<void> _resumeGuestSession() async {
    if (_guestResumeInFlight || !mounted) return;
    _guestResumeInFlight = true;
    setState(() => _guestLifecycleNotice = '正在检查 Wi-Fi 并恢复空间连接…');
    try {
      final addresses = await widget.native.getLocalAddresses();
      final wifiConnected = addresses.any(
        (address) =>
            isLikelyWifiInterface(address['interface']?.toString() ?? ''),
      );
      if (!wifiConnected) {
        throw const _GuestResumeException('尚未连接发起者的 Wi-Fi。');
      }
      await widget.dataSource.reconnect();
      await _refreshFiles();
      _consumeInterruptedUploadRetry();
      _schedulePendingUploadRetry();
      if (mounted) _snack('已恢复与 Host 的连接');
    } catch (error) {
      debugPrint('[LinkNest] 访客恢复连接失败 reason=${error.runtimeType}');
      if (mounted) {
        _snack(
          error is _GuestResumeException ? error.message : '暂时无法恢复连接，请检查热点后重试。',
        );
      }
    } finally {
      _guestResumeInFlight = false;
      if (mounted) {
        setState(() => _guestLifecycleNotice = null);
        _scheduleRefresh();
        _tryRetryInterruptedUpload();
      }
    }
  }

  void _tryRetryInterruptedUpload() {
    if (!_retryInterruptedUploadWhenIdle ||
        _adding ||
        _activeTransfer != null ||
        widget.dataSource.pendingUploadNames.value.isEmpty) {
      return;
    }
    _retryInterruptedUploadWhenIdle = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_retryPendingUploads());
    });
  }

  void _consumeInterruptedUploadRetry() {
    final lifecycleDataSource = widget.dataSource;
    if (lifecycleDataSource is! GuestLifecycleDataSource) return;
    final guestLifecycle = lifecycleDataSource as GuestLifecycleDataSource;
    if (guestLifecycle.consumeBackgroundInterruptedUpload()) {
      _retryInterruptedUploadWhenIdle = true;
    }
  }

  void _schedulePendingUploadRetry() {
    if (widget.dataSource.pendingUploadNames.value.isNotEmpty) {
      _retryInterruptedUploadWhenIdle = true;
    }
  }

  Future<void> _discardPendingUploads() async {
    if (_discardingPending || _activeTransfer != null) return;
    setState(() => _discardingPending = true);
    try {
      await widget.dataSource.discardPendingUploads();
      if (mounted) _snack('已放弃待重试文件');
    } catch (e) {
      debugPrint('[LinkNest] 清理待重试上传失败 reason=${e.runtimeType}');
      if (mounted) _snack('清理待重试文件失败：$e');
    } finally {
      if (mounted) setState(() => _discardingPending = false);
    }
  }

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    try {
      await widget.dataSource.reconnect();
      await _refreshFiles();
      _consumeInterruptedUploadRetry();
      _schedulePendingUploadRetry();
      _tryRetryInterruptedUpload();
      if (mounted) _snack('已重新连接 Host');
    } catch (e) {
      debugPrint('[LinkNest] 重新连接失败 reason=${e.runtimeType}');
      if (mounted) _snack('重新连接失败：$e');
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  void _onTransferProgress(SpaceTransferProgress progress) {
    if (mounted) setState(() => _transferProgress = progress);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _GuestResumeException implements Exception {
  const _GuestResumeException(this.message);

  final String message;
}

class _TransferProgressBar extends StatelessWidget {
  const _TransferProgressBar({required this.progress, this.onCancel});

  final SpaceTransferProgress progress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final total = progress.totalBytes;
    final value = total > 0
        ? (progress.completedBytes / total).clamp(0.0, 1.0).toDouble()
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  progress.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              if (onCancel != null)
                LinkNestAction(onPressed: onCancel, label: '取消'),
            ],
          ),
          const SizedBox(height: 2),
          value == null
              ? const FProgress()
              : FDeterminateProgress(value: value),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.state,
    required this.reconnecting,
    this.onReconnect,
    this.onLeave,
  });

  final SpaceConnectionState state;
  final bool reconnecting;
  final VoidCallback? onReconnect;
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    if (state.status == SpaceConnectionStatus.connected ||
        state.status == SpaceConnectionStatus.closed) {
      return const SizedBox.shrink();
    }
    return LinkNestNotice(
      message: state.message,
      error: state.status == SpaceConnectionStatus.incompatible,
      actions: [
        if (onReconnect != null)
          LinkNestAction(
            onPressed: reconnecting ? null : onReconnect,
            label: reconnecting ? '连接中…' : '重新连接',
          ),
        if (onLeave != null) LinkNestAction(onPressed: onLeave, label: '返回扫码'),
      ],
    );
  }
}

class _PendingUploadBanner extends StatelessWidget {
  const _PendingUploadBanner({
    required this.names,
    required this.busy,
    required this.onRetry,
    required this.onDiscard,
  });

  final List<String> names;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const SizedBox.shrink();
    final first = names.first;
    final suffix = names.length > 1 ? ' 等 ${names.length} 个文件' : '';
    return LinkNestNotice(
      message: '$first$suffix 等待重试',
      actions: [
        LinkNestAction(onPressed: busy ? null : onDiscard, label: '放弃'),
        LinkNestAction(onPressed: busy ? null : onRetry, label: '重试'),
      ],
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({required this.canAddMedia});

  final bool canAddMedia;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      canAddMedia ? '还没有内容，点右上角添加图片' : '空间里还没有内容',
      textAlign: TextAlign.center,
      style: context.theme.typography.body.sm.copyWith(
        color: context.theme.colors.mutedForeground,
        fontFamily: _galleryBodyFont,
      ),
    ),
  );
}

class _UploaderGroup {
  const _UploaderGroup(this.key, this.name, this.count, this.cover);

  final String key;

  final String name;
  final int count;
  final FileRecord cover;
}

class _PreviewImage extends StatefulWidget {
  const _PreviewImage({
    required this.dataSource,
    required this.file,
    this.fit = BoxFit.cover,
    this.background,
    this.highRes = false,
    this.showBadge = true,
    this.progressiveHighRes = false,
  });

  final SpaceDataSource dataSource;
  final FileRecord file;
  final BoxFit fit;
  final Color? background;
  final bool highRes;
  final bool showBadge;
  final bool progressiveHighRes;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  Uint8List? _bytes;
  bool _done = false;
  Size? _imageSize;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _PreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final mediaChanged =
        oldWidget.file.id != widget.file.id ||
        !oldWidget.file.hasSameMediaContentAs(widget.file);
    final sourceChanged =
        mediaChanged ||
        oldWidget.highRes != widget.highRes ||
        oldWidget.progressiveHighRes != widget.progressiveHighRes ||
        !identical(oldWidget.dataSource, widget.dataSource);
    if (sourceChanged) {
      _bytes = null;
      _done = false;
      _imageSize = null;
      unawaited(_load());
    } else if (oldWidget.file.previewStatus != widget.file.previewStatus &&
        widget.file.hasThumb &&
        _bytes == null) {
      _done = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (!widget.file.hasThumb) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _done = true);
      }
      return;
    }
    if (widget.highRes && widget.progressiveHighRes) {
      await _loadProgressivePreview(generation);
      return;
    }
    try {
      final bytes = widget.highRes
          ? await widget.dataSource.preview(widget.file.id)
          : await widget.dataSource.thumbnail(widget.file.id);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _done = true;
        if (bytes.isNotEmpty) _bytes = bytes;
      });
      if (bytes.isNotEmpty && widget.highRes) {
        await _decodeSize(bytes, generation);
      }
    } catch (e) {
      debugPrint(
        '[LinkNest] 加载预览失败 id=${widget.file.id} reason=${e.runtimeType}',
      );
      if (mounted && generation == _loadGeneration) {
        setState(() => _done = true);
      }
    }
  }

  Future<void> _loadProgressivePreview(int generation) async {
    final highRes = widget.dataSource.preview(widget.file.id);
    try {
      final thumbnail = await widget.dataSource.thumbnail(widget.file.id);
      if (mounted && generation == _loadGeneration && thumbnail.isNotEmpty) {
        setState(() {
          _bytes = thumbnail;
          _done = true;
        });
        debugPrint('[LinkNest] 查看器缩略图已就绪 id=${widget.file.id}');
      }
    } catch (error) {
      debugPrint(
        '[LinkNest] 查看器缩略图加载失败 id=${widget.file.id} reason=${error.runtimeType}',
      );
    }

    try {
      final bytes = await highRes;
      if (!mounted || generation != _loadGeneration) return;
      if (bytes.isNotEmpty) await precacheImage(MemoryImage(bytes), context);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _done = true;
        if (bytes.isNotEmpty) _bytes = bytes;
      });
      debugPrint('[LinkNest] 查看器高清预览已就绪 id=${widget.file.id}');
    } catch (error) {
      debugPrint(
        '[LinkNest] 查看器高清预览加载失败 id=${widget.file.id} reason=${error.runtimeType}',
      );
      if (mounted && generation == _loadGeneration) {
        setState(() => _done = true);
      }
    }
  }

  Future<void> _decodeSize(Uint8List bytes, int generation) async {
    try {
      final info = await decodeImageFromList(bytes);
      final size = Size(info.width.toDouble(), info.height.toDouble());
      info.dispose();
      if (mounted && generation == _loadGeneration) {
        setState(() => _imageSize = size);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.background ?? context.theme.colors.muted;
    final foreground = widget.background == null
        ? context.theme.colors.mutedForeground
        : Colors.white70;
    if (widget.highRes && _bytes != null && _imageSize != null) {
      return _buildHighRes();
    }
    final Widget content;
    if (!widget.file.hasThumb) {
      content = Container(
        color: background,
        child: Icon(FLucideIcons.file, color: foreground, size: 32),
      );
    } else if (_bytes != null) {
      content = Image.memory(
        gaplessPlayback: true,
        _bytes!,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
      );
    } else if (_done) {
      content = Container(
        color: background,
        child: Icon(
          widget.file.kind == 'video' ? FLucideIcons.film : FLucideIcons.image,
          color: foreground,
          size: 32,
        ),
      );
    } else {
      content = Container(
        color: background,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (widget.showBadge)
          Positioned(right: 4, bottom: 4, child: _formatBadge(widget.file)),
      ],
    );
  }

  Widget _buildHighRes() {
    final bytes = _bytes!;
    final imageSize = _imageSize!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        if (maxWidth <= 0 ||
            maxHeight <= 0 ||
            imageSize.width <= 0 ||
            imageSize.height <= 0) {
          return Center(child: Image.memory(bytes, fit: BoxFit.contain));
        }
        final scale = math.min(
          maxWidth / imageSize.width,
          maxHeight / imageSize.height,
        );
        final width = imageSize.width * scale;
        final height = imageSize.height * scale;
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  gaplessPlayback: true,
                  bytes,
                  fit: BoxFit.fill,
                  width: width,
                  height: height,
                ),
                if (widget.showBadge)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: _formatBadge(widget.file),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Widget _formatBadge(FileRecord file) {
  if (file.isLivePhoto) {
    return _badge('Live');
  }
  final dot = file.name.lastIndexOf('.');
  if (dot < 0 || dot == file.name.length - 1) {
    return const SizedBox.shrink();
  }
  return _badge(file.name.substring(dot + 1).toUpperCase());
}

Widget _badge(String label) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
  decoration: BoxDecoration(
    color: Colors.black45,
    borderRadius: BorderRadius.circular(3),
  ),
  child: Text(
    label,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 10,
      fontWeight: FontWeight.w500,
    ),
  ),
);

class _LivePhotoView extends StatefulWidget {
  const _LivePhotoView({
    super.key,
    required this.dataSource,
    required this.file,
  });

  final SpaceDataSource dataSource;
  final FileRecord file;

  @override
  State<_LivePhotoView> createState() => _LivePhotoViewState();
}

class _LivePhotoViewState extends State<_LivePhotoView> {
  final SpaceTransferCancellation _cancellation = SpaceTransferCancellation();
  LocalOriginal? _original;
  Object? _error;
  MethodChannel? _playbackChannel;
  bool _pressing = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final original = await widget.dataSource.materializeOriginal(
        widget.file,
        cancellation: _cancellation,
      );
      if (!mounted) {
        await original.dispose();
        return;
      }
      setState(() => _original = original);
    } on SpaceTransferCancelledException {
      // 页面切换或退出时的正常清理。
    } catch (error) {
      debugPrint(
        '[LinkNest] 准备 Live Photo 失败 id=${widget.file.id} reason=${error.runtimeType}',
      );
      if (mounted) setState(() => _error = error);
    }
  }

  void _onPlatformViewCreated(int viewId) {
    _playbackChannel = MethodChannel('linknest/live-photo/$viewId');
    debugPrint(
      '[LinkNest] Live Photo 原生视图已创建 id=${widget.file.id} viewId=$viewId',
    );
    if (_pressing) unawaited(_sendPlayback('startPlayback'));
  }

  Future<void> _sendPlayback(String action) async {
    try {
      await _playbackChannel?.invokeMethod<void>(action);
    } catch (error) {
      debugPrint(
        '[LinkNest] Live Photo 播放操作失败 id=${widget.file.id} '
        'action=$action reason=${error.runtimeType}',
      );
    }
  }

  void _setPressing(bool pressing) {
    if (_pressing == pressing) return;
    _pressing = pressing;
    debugPrint(
      '[LinkNest] Live Photo 长按${pressing ? '开始' : '结束'} id=${widget.file.id}',
    );
    if (_playbackChannel != null) {
      unawaited(_sendPlayback(pressing ? 'startPlayback' : 'stopPlayback'));
    }
  }

  @override
  void dispose() {
    _setPressing(false);
    _playbackChannel = null;
    _cancellation.cancel();
    final original = _original;
    if (original != null) unawaited(original.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    final pairedPath = original?.pairedVideoPath;
    if (original == null || pairedPath == null) {
      if (_error != null) {
        return const IgnorePointer(
          child: Center(
            child: Icon(Icons.broken_image_outlined, color: Colors.white70),
          ),
        );
      }
      return const IgnorePointer(
        child: Center(child: CircularProgressIndicator(color: Colors.white70)),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _setPressing(true),
      onLongPressEnd: (_) => _setPressing(false),
      child: UiKitView(
        viewType: 'linknest/live-photo',
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParamsCodec: const StandardMessageCodec(),
        creationParams: {
          'photoPath': original.path,
          'photoName': widget.file.photoResource!.name,
          'pairedVideoPath': pairedPath,
          'pairedVideoName': widget.file.pairedVideo!.name,
        },
      ),
    );
  }
}

class _AndroidLivePhotoView extends StatefulWidget {
  const _AndroidLivePhotoView({
    super.key,
    required this.dataSource,
    required this.file,
  });

  final SpaceDataSource dataSource;
  final FileRecord file;

  @override
  State<_AndroidLivePhotoView> createState() => _AndroidLivePhotoViewState();
}

class _AndroidLivePhotoViewState extends State<_AndroidLivePhotoView> {
  final SpaceTransferCancellation _cancellation = SpaceTransferCancellation();
  LocalOriginal? _original;
  VideoPlayerController? _controller;
  bool _pressing = false;
  bool _playing = false;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    LocalOriginal? original;
    VideoPlayerController? controller;
    try {
      original = await widget.dataSource.materializeOriginal(
        widget.file,
        cancellation: _cancellation,
      );
      final pairedPath = original.pairedVideoPath;
      if (pairedPath == null) {
        throw StateError('Live Photo paired video missing');
      }
      controller = VideoPlayerController.file(File(pairedPath));
      await controller.initialize();
      if (!mounted) return;
      _original = original;
      _controller = controller;
      original = null;
      controller = null;
      if (_pressing) unawaited(_startPlayback());
    } on SpaceTransferCancelledException {
      // 页面切换时停止准备资源。
    } catch (error) {
      debugPrint(
        '[LinkNest] Android Live Photo 播放不可用 id=${widget.file.id} '
        'reason=${error.runtimeType}',
      );
      if (mounted) setState(() => _unavailable = true);
    } finally {
      await controller?.dispose();
      await original?.dispose();
    }
  }

  Future<void> _startPlayback() async {
    final controller = _controller;
    if (controller == null || !_pressing || !mounted) return;
    try {
      await controller.seekTo(Duration.zero);
      if (!_pressing || !mounted) return;
      await controller.play();
      if (!_pressing || !mounted) {
        await controller.pause();
        return;
      }
      setState(() => _playing = true);
    } catch (error) {
      debugPrint(
        '[LinkNest] Android Live Photo 长按播放失败 id=${widget.file.id} '
        'reason=${error.runtimeType}',
      );
      if (mounted) setState(() => _unavailable = true);
    }
  }

  void _stopPlayback() {
    _pressing = false;
    if (_playing) setState(() => _playing = false);
    final controller = _controller;
    if (controller != null) unawaited(controller.pause());
  }

  @override
  void dispose() {
    _cancellation.cancel();
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    final original = _original;
    if (original != null) unawaited(original.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) {
        _pressing = true;
        if (_unavailable) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('此设备暂不支持播放这张 Live Photo')),
          );
        } else {
          unawaited(_startPlayback());
        }
      },
      onLongPressEnd: (_) => _stopPlayback(),
      child: _playing && controller != null
          ? Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            )
          : const SizedBox.expand(),
    );
  }
}

class _ViewerScreen extends StatefulWidget {
  const _ViewerScreen({
    required this.dataSource,
    required this.native,
    required this.files,
    required this.initialIndex,
    required this.guestMode,
    this.videoControllerFactory,
    this.localVideoControllerFactory,
  });

  final SpaceDataSource dataSource;
  final LinkNestNative native;
  final List<FileRecord> files;
  final int initialIndex;
  final bool guestMode;
  final NetworkVideoControllerFactory? videoControllerFactory;
  final LocalVideoControllerFactory? localVideoControllerFactory;

  @override
  State<_ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<_ViewerScreen>
    with WidgetsBindingObserver {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _saving = false;
  bool _closing = false;
  SpaceTransferCancellation? _saveCancellation;
  SpaceTransferProgress? _saveProgress;
  final Map<String, PhotoViewController> _photoControllers = {};
  final Map<String, PhotoViewScaleStateController> _scaleControllers = {};
  final LinkedHashMap<String, _VideoPlaybackSession> _videoSessions =
      LinkedHashMap();

  FileRecord get _current => widget.files[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activateVideoAt(_index);
    unawaited(_preloadAround(_index));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      for (final session in _videoSessions.values) {
        unawaited(session.pause());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveCancellation?.cancel();
    for (final session in _videoSessions.values) {
      session.close();
    }
    _videoSessions.clear();
    for (final controller in _photoControllers.values) {
      controller.dispose();
    }
    _photoControllers.clear();
    for (final controller in _scaleControllers.values) {
      controller.dispose();
    }
    _scaleControllers.clear();
    _controller.dispose();
    super.dispose();
  }

  void _activateVideoAt(int index) {
    for (final session in _videoSessions.values) {
      unawaited(session.pause());
    }
    final file = widget.files[index];
    if (file.kind != 'video') return;
    final existing = _videoSessions.remove(file.id);
    _videoSessions[file.id] =
        existing ??
        _VideoPlaybackSession(
          dataSource: widget.dataSource,
          file: file,
          guestMode: widget.guestMode,
          networkControllerFactory:
              widget.videoControllerFactory ?? _createNetworkVideoController,
          localControllerFactory:
              widget.localVideoControllerFactory ?? _createLocalVideoController,
        );
    while (_videoSessions.length > 2) {
      final oldestId = _videoSessions.keys.first;
      _videoSessions.remove(oldestId)?.close();
      debugPrint('[LinkNest] 已释放最久未使用的视频会话 id=$oldestId');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final cancellation = SpaceTransferCancellation();
    setState(() {
      _saving = true;
      _saveCancellation = cancellation;
      _saveProgress = null;
    });
    final current = _current;
    var message = '保存失败';
    try {
      final result = await _saveOriginal(
        dataSource: widget.dataSource,
        native: widget.native,
        record: current,
        cancellation: cancellation,
        onProgress: (progress) {
          if (mounted) setState(() => _saveProgress = progress);
        },
      );
      if (mounted) setState(() => _saveCancellation = null);
      message = _saveResultMessage(current, result);
    } on SpaceTransferCancelledException {
      message = '已取消保存';
    } catch (e) {
      debugPrint('[LinkNest] 保存原文件失败 id=${current.id} reason=${e.runtimeType}');
      message = '保存失败：$e';
    } finally {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        setState(() {
          _saving = false;
          _saveCancellation = null;
          _saveProgress = null;
        });
      }
    }
  }

  PhotoViewController _photoController(FileRecord file) {
    return _photoControllers.putIfAbsent(
      file.id,
      () => PhotoViewController(initialScale: 1),
    );
  }

  PhotoViewScaleStateController _scaleController(FileRecord file) {
    return _scaleControllers.putIfAbsent(
      file.id,
      PhotoViewScaleStateController.new,
    );
  }

  Future<void> _preloadAround(int center) async {
    final indexes = <int>{center, center - 1, center + 1};
    for (final index in indexes) {
      if (index < 0 || index >= widget.files.length) continue;
      final file = widget.files[index];
      if (file.kind != 'image' || file.isLivePhoto || !file.hasThumb) continue;
      try {
        await widget.dataSource.preview(file.id);
        debugPrint('[LinkNest] 已预加载查看器媒体 id=${file.id}');
      } catch (error) {
        debugPrint(
          '[LinkNest] 预加载查看器媒体失败 id=${file.id} reason=${error.runtimeType}',
        );
      }
    }
  }

  void _resetImageAt(int index) {
    if (index < 0 || index >= widget.files.length) return;
    final file = widget.files[index];
    _photoControllers[file.id]?.reset();
    _scaleControllers[file.id]?.reset();
  }

  void _closeViewer() {
    if (_closing) return;
    _closing = true;
    _resetImageAt(_index);
    debugPrint('[LinkNest] 请求关闭大图 id=${_current.id}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) popLinkNest(context);
    });
  }

  Widget _buildPage(FileRecord file, int index) {
    final preview = _PreviewImage(
      dataSource: widget.dataSource,
      file: file,
      fit: BoxFit.contain,
      background: Colors.black,
      highRes: true,
      showBadge: !file.isLivePhoto,
    );
    if (file.kind == 'video' && index == _index) {
      return _VideoPlaybackView(
        key: ValueKey('video-${file.id}'),
        session: _videoSessions[file.id]!,
        preview: preview,
      );
    }
    if (file.kind == 'image' && !file.isLivePhoto) {
      return RepaintBoundary(
        key: ValueKey('image-${file.id}'),
        child: _PreviewImage(
          dataSource: widget.dataSource,
          file: file,
          fit: BoxFit.contain,
          background: Colors.transparent,
          highRes: true,
          showBadge: false,
          progressiveHighRes: true,
        ),
      );
    }
    return Stack(
      key: ValueKey(file.id),
      fit: StackFit.expand,
      children: [
        preview,
        if (file.isLivePhoto && Platform.isIOS && index == _index)
          _LivePhotoView(
            key: ValueKey('live-${file.id}'),
            dataSource: widget.dataSource,
            file: file,
          ),
        if (file.isLivePhoto && Platform.isAndroid && index == _index)
          _AndroidLivePhotoView(
            key: ValueKey('live-android-${file.id}'),
            dataSource: widget.dataSource,
            file: file,
          ),
        if (file.isLivePhoto)
          Positioned(right: 12, bottom: 24, child: _formatBadge(file)),
      ],
    );
  }

  PhotoViewGalleryPageOptions _buildPageOptions(
    BuildContext context,
    int index,
  ) {
    final file = widget.files[index];
    final isPhoto = file.kind == 'image' && !file.isLivePhoto;
    if (!isPhoto) {
      return PhotoViewGalleryPageOptions.customChild(
        child: _buildPage(file, index),
        initialScale: 1.0,
        minScale: 1.0,
        maxScale: 1.0,
        disableGestures: true,
      );
    }
    final viewportSize = MediaQuery.sizeOf(context);
    return PhotoViewGalleryPageOptions.customChild(
      childSize: viewportSize,
      child: SizedBox.fromSize(
        size: viewportSize,
        child: _buildPage(file, index),
      ),
      heroAttributes: index == _index && !LinkNestMotion.reduced(context)
          ? PhotoViewHeroAttributes(tag: _viewerHeroTag(file))
          : null,
      controller: _photoController(file),
      scaleStateController: _scaleController(file),
      initialScale: 1.0,
      minScale: 1.0,
      maxScale: 4.0,
      basePosition: Alignment.center,
      gestureDetectorBehavior: HitTestBehavior.opaque,
      filterQuality: FilterQuality.none,
      // PageView builds adjacent items too. Only the selected page may claim
      // pinch/pan gestures so a multi-touch sequence cannot affect neighbors.
      disableGestures: index != _index,
      onScaleEnd: (context, details, value) {
        debugPrint(
          '[LinkNest] 大图缩放手势结束 id=${file.id} '
          'scale=${(value.scale ?? 1).toStringAsFixed(2)}',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final animation = LinkNestMotion.reduced(context)
        ? kAlwaysCompleteAnimation
        : (ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation).drive(
            CurveTween(curve: LinkNestMotion.curve),
          );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: FadeTransition(
              key: const ValueKey('viewer-backdrop'),
              opacity: animation,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
          PhotoViewGallery.builder(
            pageController: _controller,
            backgroundDecoration: const BoxDecoration(
              color: Colors.transparent,
            ),
            gaplessPlayback: true,
            allowImplicitScrolling: true,
            scrollPhysics: const PageScrollPhysics(),
            onPageChanged: (index) {
              final previousIndex = _index;
              _activateVideoAt(index);
              setState(() {
                _index = index;
              });
              unawaited(_preloadAround(index));
              debugPrint('[LinkNest] 大图切换文件 from=$previousIndex to=$index');
            },
            itemCount: widget.files.length,
            builder: _buildPageOptions,
          ),
          FadeTransition(
            opacity: animation,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(FLucideIcons.x, color: Colors.white),
                          tooltip: '关闭预览',
                          onPressed: _closeViewer,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${_index + 1} / ${widget.files.length}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: _galleryBodyFont,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.dataSource.capabilities.canSaveOriginals)
                        Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          child: Tooltip(
                            message: _saveCancellation != null
                                ? '取消下载'
                                : _saveActionLabel(_current),
                            child: TextButton.icon(
                              onPressed: !_canSaveRecord(_current)
                                  ? null
                                  : _saveCancellation != null
                                  ? _saveCancellation!.cancel
                                  : _saving
                                  ? null
                                  : _save,
                              icon: _saveCancellation != null
                                  ? const Icon(FLucideIcons.x, size: 18)
                                  : _saving
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(FLucideIcons.download, size: 18),
                              label: Text(
                                _saveCancellation != null
                                    ? '取消'
                                    : _saving
                                    ? '保存中'
                                    : _saveActionLabel(_current),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontFamily: _galleryBodyFont,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                disabledForegroundColor: Colors.white54,
                                minimumSize: const Size(44, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_saveProgress != null)
            FadeTransition(
              opacity: animation,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 62, 16, 0),
                    child: LinearProgressIndicator(
                      value: _saveProgress!.totalBytes > 0
                          ? (_saveProgress!.completedBytes /
                                    _saveProgress!.totalBytes)
                                .clamp(0.0, 1.0)
                                .toDouble()
                          : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VideoPlaybackSession extends ChangeNotifier {
  _VideoPlaybackSession({
    required SpaceDataSource dataSource,
    required this.file,
    required this.guestMode,
    required this.networkControllerFactory,
    required this.localControllerFactory,
  }) : _dataSource = dataSource,
       networkSource = guestMode
           ? _resolveNetworkVideoSource(dataSource, file)
           : null;

  final SpaceDataSource _dataSource;
  final FileRecord file;
  final bool guestMode;
  final NetworkVideoControllerFactory networkControllerFactory;
  final LocalVideoControllerFactory localControllerFactory;
  final NetworkVideoPlaybackSource? networkSource;

  VideoPlayerController? _controller;
  VideoPlayerController? _pendingController;
  LocalOriginal? _localOriginal;
  LocalOriginal? _pendingOriginal;
  Object? _error;
  bool _preparing = false;
  bool _closed = false;
  int _operationGeneration = 0;
  final Set<VideoPlayerController> _disposedControllers =
      HashSet<VideoPlayerController>.identity();

  VideoPlayerController? get controller => _controller;
  Object? get error => _error;
  bool get preparing => _preparing;
  bool get canStream => networkSource != null;
  bool get canPlay => !guestMode || canStream;

  Future<void> startAndPlay() async {
    if (_closed || _preparing || !canPlay) return;
    final generation = ++_operationGeneration;
    _preparing = true;
    _error = null;
    notifyListeners();

    VideoPlayerController? candidate;
    try {
      await _releaseActiveController();
      if (_closed || generation != _operationGeneration) return;
      if (guestMode) {
        debugPrint('[LinkNest] 已开始读取访客视频流 id=${file.id}');
        candidate = networkControllerFactory(networkSource!);
      } else {
        final original = await _prepareLocalVideoForPlayback(_dataSource, file);
        if (_closed || generation != _operationGeneration) {
          await original.dispose();
          return;
        }
        _pendingOriginal = original;
        candidate = localControllerFactory(File(original.path));
      }
      _pendingController = candidate;
      await candidate.initialize().timeout(const Duration(seconds: 20));
      if (_closed || generation != _operationGeneration) {
        await _disposeController(candidate);
        await _pendingOriginal?.dispose();
        _pendingOriginal = null;
        return;
      }
      _pendingController = null;
      _localOriginal = _pendingOriginal;
      _pendingOriginal = null;
      _controller = candidate;
      _preparing = false;
      notifyListeners();
      await candidate.play();
      debugPrint(
        '[LinkNest] 视频开始播放 id=${file.id} '
        'source=${guestMode ? 'range' : 'local'}',
      );
    } catch (error) {
      await _disposeController(candidate);
      if (identical(_controller, candidate)) await _releaseActiveController();
      await _pendingOriginal?.dispose();
      _pendingOriginal = null;
      debugPrint(
        '[LinkNest] 视频播放失败 id=${file.id} '
        'source=${guestMode ? 'range' : 'local'} reason=${error.runtimeType}'
        '${error is PlatformException ? ' code=${error.code} message=${error.message}' : ''}',
      );
      if (!_closed && generation == _operationGeneration) {
        _pendingController = null;
        _controller = null;
        _preparing = false;
        _error = error;
        notifyListeners();
      }
    }
  }

  void cancelPreparation() {
    if (!_preparing) return;
    _operationGeneration++;
    final pending = _pendingController;
    _pendingController = null;
    if (pending != null) unawaited(_disposeController(pending));
    final original = _pendingOriginal;
    _pendingOriginal = null;
    if (original != null) unawaited(original.dispose());
    debugPrint('[LinkNest] 已取消准备视频 id=${file.id}');
    _resetPreparation();
  }

  void _resetPreparation() {
    _preparing = false;
    _error = null;
    notifyListeners();
  }

  Future<void> togglePlayback() async {
    final active = _controller;
    if (active == null || !active.value.isInitialized) return;
    final value = active.value;
    if (_isVideoCompleted(value)) {
      await active.pause();
      await active.seekTo(Duration.zero);
      await active.play();
      debugPrint('[LinkNest] 已重新播放视频 id=${file.id}');
    } else if (value.isPlaying) {
      await active.pause();
    } else {
      await active.play();
    }
  }

  Future<void> pause() async {
    final active = _controller;
    if (active == null || !active.value.isPlaying) return;
    try {
      await active.pause();
    } catch (error) {
      debugPrint(
        '[LinkNest] 暂停访客视频失败 id=${file.id} '
        'reason=${error.runtimeType}',
      );
    }
  }

  Future<void> _releaseActiveController() async {
    final active = _controller;
    _controller = null;
    await _disposeController(active);
    final original = _localOriginal;
    _localOriginal = null;
    await original?.dispose();
  }

  Future<void> _disposeController(VideoPlayerController? controller) async {
    if (controller == null || !_disposedControllers.add(controller)) return;
    try {
      await controller.dispose();
    } catch (error) {
      debugPrint(
        '[LinkNest] 释放访客视频控制器失败 id=${file.id} '
        'reason=${error.runtimeType}',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _operationGeneration++;
    final pending = _pendingController;
    _pendingController = null;
    if (pending != null) unawaited(_disposeController(pending));
    final original = _pendingOriginal;
    _pendingOriginal = null;
    if (original != null) unawaited(original.dispose());
    unawaited(_releaseActiveController());
    super.dispose();
  }
}

class _VideoPlaybackView extends StatelessWidget {
  const _VideoPlaybackView({
    super.key,
    required this.session,
    required this.preview,
  });

  final _VideoPlaybackSession session;
  final Widget preview;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final controller = session.controller;
      return Stack(
        fit: StackFit.expand,
        children: [
          preview,
          if (controller != null && controller.value.isInitialized)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) => ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio > 0
                        ? value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
            ),
          if (session.preparing)
            _buildPreparationOverlay()
          else if (controller == null)
            _buildStartOverlay()
          else
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) => value.hasError
                  ? _buildRuntimeErrorOverlay()
                  : _buildPlaybackControls(controller, value),
            ),
        ],
      );
    },
  );

  // 媒体始终为黑底，操作使用公共按钮的深色主题，保证浅色 App 下也可读。
  Widget _videoAction({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    bool secondary = false,
  }) => FTheme(
    data: linkNestDarkForuiTheme,
    child: LinkNestButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      variant: secondary ? FButtonVariant.secondary : FButtonVariant.primary,
    ),
  );

  Widget _buildPreparationOverlay() {
    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 180, child: const LinearProgressIndicator()),
              const SizedBox(height: 10),
              const Text('正在连接视频…', style: TextStyle(color: Colors.white)),
              _videoAction(
                label: '取消',
                onPressed: session.cancelPreparation,
                secondary: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStartOverlay() {
    final failed = session.error != null;
    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    session.guestMode
                        ? '在线播放失败，请重试；仍无法播放时请先保存到相册'
                        : '播放失败，请重试；仍无法播放时请先保存到相册',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              if (session.canPlay)
                _videoAction(
                  onPressed: session.startAndPlay,
                  icon: failed ? FLucideIcons.rotateCw : FLucideIcons.play,
                  label: session.guestMode
                      ? (failed ? '重试在线播放' : '在线播放')
                      : (failed ? '重试播放' : '播放视频'),
                ),
              if (!session.canPlay)
                const Text(
                  '当前 Host 不支持在线播放，请先保存到相册',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              const SizedBox(height: 6),
              const Text(
                '保存到相册请使用右上角按钮',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRuntimeErrorOverlay() => Center(
    child: Material(
      color: Colors.black.withValues(alpha: 0.76),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('视频连接已中断', style: TextStyle(color: Colors.white)),
            const SizedBox(height: 8),
            if (session.canPlay)
              _videoAction(
                label: session.guestMode ? '重试在线播放' : '重试播放',
                icon: FLucideIcons.rotateCw,
                onPressed: session.startAndPlay,
              ),
            const SizedBox(height: 8),
            const Text(
              '仍无法播放时，请使用右上角按钮保存到相册',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildPlaybackControls(
    VideoPlayerController controller,
    VideoPlayerValue value,
  ) {
    final completed = _isVideoCompleted(value);
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                tooltip: completed
                    ? '重新播放'
                    : value.isPlaying
                    ? '暂停'
                    : '播放',
                onPressed: session.togglePlayback,
                icon: Icon(
                  completed
                      ? Icons.replay
                      : value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
              ),
              Expanded(
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: linkNestDarkForuiTheme.colors.primary,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${_formatPlaybackDuration(value.position)} / '
                '${_formatPlaybackDuration(value.duration)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatPlaybackDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

bool _isVideoCompleted(VideoPlayerValue value) {
  if (value.isCompleted) return true;
  final duration = value.duration;
  if (duration <= Duration.zero) return false;
  final threshold = duration > const Duration(milliseconds: 200)
      ? duration - const Duration(milliseconds: 200)
      : duration;
  return value.position >= threshold;
}
