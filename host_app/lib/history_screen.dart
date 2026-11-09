import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_ui.dart';

import 'server.dart';
import 'guest_space_history.dart';

const _historyAccordionStyle = FAccordionStyleDelta.delta(
  dividerStyle: FDividerStyleDelta.delta(color: Colors.transparent),
);

class HistorySpacesScreen extends StatefulWidget {
  const HistorySpacesScreen({
    super.key,
    required this.server,
    required this.allowResume,
    this.includeJoinedSpaces = false,
    this.guestCacheRemover,
  });

  final LinkNestServer server;
  final bool allowResume;
  final bool includeJoinedSpaces;
  final GuestSpaceCacheRemover? guestCacheRemover;

  @override
  State<HistorySpacesScreen> createState() => _HistorySpacesScreenState();
}

class _HistorySpacesScreenState extends State<HistorySpacesScreen> {
  List<HistorySpaceSnapshot> _spaces = const [];
  List<RecentGuestSpace> _joinedSpaces = const [];
  bool _loading = true;
  final Set<String> _deletingGuestIds = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load(resolveLocations: true));
  }

  Future<void> _load({bool resolveLocations = false}) async {
    var spaces = <HistorySpaceSnapshot>[];
    var joined = <RecentGuestSpace>[];
    final errors = <String>[];
    try {
      spaces = await widget.server.historySpaces();
    } catch (error) {
      debugPrint('[LinkNest] 发起者历史读取失败 reason=${error.runtimeType}');
      errors.add('本机创建记录读取失败');
    }
    if (widget.includeJoinedSpaces) {
      try {
        joined = (await GuestSpaceHistory.open(
          cacheRemover: widget.guestCacheRemover,
        )).spaces;
      } catch (error) {
        debugPrint('[LinkNest] 参与者历史读取失败 reason=${error.runtimeType}');
        errors.add('参与记录读取失败');
      }
    }
    if (!mounted) return;
    setState(() {
      _spaces = spaces;
      _joinedSpaces = joined;
      _loading = false;
      _error = errors.isEmpty ? null : errors.join('；');
    });
    debugPrint(
      '[LinkNest] 历史空间已加载 host=${spaces.length} guest=${joined.length}',
    );
    if (resolveLocations && spaces.isNotEmpty) {
      try {
        await widget.server.resolveHistoryLocations();
        final refreshed = await widget.server.historySpaces();
        if (mounted) setState(() => _spaces = refreshed);
      } catch (error) {
        debugPrint('[LinkNest] 历史地点刷新失败 reason=${error.runtimeType}');
      }
    }
  }

  List<_HistoryEntry> get _entries {
    final hostedIds = _spaces.map((s) => s.space.id).toSet();
    return [
      for (final space in _spaces) _HistoryEntry(host: space),
      for (final space in _joinedSpaces)
        if (!hostedIds.contains(space.spaceId)) _HistoryEntry(guest: space),
    ]..sort((a, b) {
      final time = b.time.compareTo(a.time);
      return time != 0 ? time : a.key.compareTo(b.key);
    });
  }

  Future<bool> _confirm(String title, String message) async =>
      await showLinkNestDialog<bool>(
        context: context,
        builder: (context) => LinkNestDialog(
          title: title,
          actions: [
            LinkNestButton(
              onPressed: () => popLinkNest(context, false),
              label: '取消',
              variant: FButtonVariant.secondary,
            ),
            LinkNestButton(
              onPressed: () => popLinkNest(context, true),
              label: '删除',
              variant: FButtonVariant.destructive,
            ),
          ],
          child: Text(message),
        ),
      ) ??
      false;

  Future<void> _deleteSpace(HistorySpaceSnapshot snapshot) async {
    if (!await _confirm('删除历史空间', '空间内的所有照片和视频将永久删除。')) return;
    debugPrint(
      '[LinkNest] 开始删除历史空间 spaceId=${snapshot.space.id} fileCount=${snapshot.files.length}',
    );
    try {
      await widget.server.deleteHistorySpace(snapshot.space.id);
      debugPrint('[LinkNest] 历史空间删除完成 spaceId=${snapshot.space.id}');
      await _load();
    } catch (error) {
      debugPrint('[LinkNest] 历史空间删除失败 reason=${error.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$error')));
    }
  }

  Future<void> _deleteGuestRecord(RecentGuestSpace space) async {
    if (_deletingGuestIds.contains(space.spaceId)) return;
    setState(() => _deletingGuestIds.add(space.spaceId));
    try {
      if (!await _confirm(
        '删除参与记录',
        '将删除本机的这条参与记录及对应媒体缓存，不删除发起者的空间、文件或已保存到系统相册的内容。',
      )) {
        return;
      }
      if (!mounted) return;
      debugPrint('[LinkNest] 开始删除本机参与记录');
      await (await GuestSpaceHistory.open(
        cacheRemover: widget.guestCacheRemover,
      )).remove(space.spaceId);
      if (!mounted) return;
      await _load();
    } catch (error) {
      debugPrint('[LinkNest] 删除本机参与记录失败 reason=${error.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('删除记录失败，请重试')));
    } finally {
      if (mounted) setState(() => _deletingGuestIds.remove(space.spaceId));
    }
  }

  Future<void> _open(HistorySpaceSnapshot snapshot) async {
    debugPrint(
      '[LinkNest] 打开历史空间详情 active=${snapshot.isActive} fileCount=${snapshot.files.length}',
    );
    await pushLinkNestRoute<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            HistorySpaceDetailScreen(server: widget.server, snapshot: snapshot),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return LinkNestPage(
      title: '历史空间',
      child: RefreshIndicator(
        onRefresh: () => _load(resolveLocations: true),
        child: Column(
          children: [
            if (_error != null && _entries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: LinkNestNotice(message: '$_error；下拉可重试', error: true),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = context.theme;
    if (_loading) return const Center(child: FCircularProgress());
    final entries = _entries;
    if (entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 64, 20, 24),
        children: [
          Icon(
            FLucideIcons.folderClock,
            size: 48,
            color: theme.colors.mutedForeground,
          ),
          const SizedBox(height: 24),
          Text(
            _error ?? '还没有历史空间',
            textAlign: TextAlign.center,
            style: theme.typography.body.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error == null ? '创建或加入空间后，可从这里再次进入。' : '下拉页面可重新读取。',
            textAlign: TextAlign.center,
            style: theme.typography.body.sm.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return KeyedSubtree(
          key: ValueKey(entry.key),
          child: entry.host != null
              ? _buildHostCard(entry.host!)
              : _buildGuestCard(entry.guest!),
        );
      },
    );
  }

  Widget _buildHostCard(HistorySpaceSnapshot snapshot) {
    final locations = snapshot.locationLabels.take(3).join('、');
    return _HistoryListItem(
      title: snapshot.space.name,
      role: '发起者',
      active: snapshot.isActive,
      time: _dateTime(snapshot.space.lastActivityAt.toLocal()),
      details:
          '${snapshot.files.length} 个文件 · ${_bytes(snapshot.totalBytes)}${locations.isEmpty ? '' : ' · $locations'}',
      icon: FLucideIcons.folder,
      onTap: () => _open(snapshot),
      actions: [
        if (!snapshot.isActive) ...[
          if (widget.allowResume)
            LinkNestAction(
              label: '继续共享',
              icon: FLucideIcons.play,
              onPressed: () {
                debugPrint('[LinkNest] 历史页继续共享本机空间');
                popLinkNest(context, snapshot.space);
              },
            ),
          LinkNestAction(
            label: '删除空间',
            icon: FLucideIcons.trash2,
            onPressed: () => _deleteSpace(snapshot),
          ),
        ],
      ],
    );
  }

  Widget _buildGuestCard(RecentGuestSpace space) {
    void enter() {
      debugPrint('[LinkNest] 历史页选择参与者空间，使用保存地址');
      popLinkNest(context, space);
    }

    final deleting = _deletingGuestIds.contains(space.spaceId);
    return _HistoryListItem(
      title: space.name,
      role: '参与者',
      time: _dateTime(space.lastJoinedAt.toLocal()),
      details: '连接发起者当前热点后，尝试上次空间地址。',
      icon: FLucideIcons.users,
      onTap: deleting ? null : enter,
      actions: [
        LinkNestAction(
          label: '进入空间',
          icon: FLucideIcons.logIn,
          onPressed: deleting ? null : enter,
        ),
        LinkNestAction(
          label: '删除记录',
          icon: FLucideIcons.trash2,
          onPressed: deleting ? null : () => _deleteGuestRecord(space),
        ),
      ],
    );
  }
}

/// 图标、名称和时间集中展示，操作轻量排列，长名称仍完整换行。
class _HistoryListItem extends StatelessWidget {
  const _HistoryListItem({
    required this.title,
    required this.role,
    required this.time,
    required this.details,
    required this.icon,
    required this.onTap,
    required this.actions,
    this.active = false,
  });
  final String title;
  final String role;
  final String time;
  final String details;
  final IconData icon;
  final VoidCallback? onTap;
  final List<Widget> actions;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final secondary = theme.typography.body.sm.copyWith(
      fontSize: 12,
      color: theme.colors.mutedForeground,
    );
    return LinkNestSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: theme.colors.secondary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, size: 22, color: theme.colors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.typography.body.md.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            Text(
                              role,
                              style: secondary.copyWith(
                                color: theme.colors.primary,
                              ),
                            ),
                            if (active)
                              Text(
                                '共享中',
                                style: secondary.copyWith(
                                  color: theme.colors.primary,
                                ),
                              ),
                            Text(time, style: secondary),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(details, style: secondary),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    FLucideIcons.chevronRight,
                    size: 18,
                    color: theme.colors.mutedForeground,
                  ),
                ],
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: actions,
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryEntry {
  const _HistoryEntry({this.host, this.guest});
  final HistorySpaceSnapshot? host;
  final RecentGuestSpace? guest;
  DateTime get time => host?.space.lastActivityAt ?? guest!.lastJoinedAt;
  String get key =>
      host != null ? 'host:${host!.space.id}' : 'guest:${guest!.spaceId}';
}

class HistorySpaceDetailScreen extends StatefulWidget {
  const HistorySpaceDetailScreen({
    super.key,
    required this.server,
    required this.snapshot,
  });

  final LinkNestServer server;
  final HistorySpaceSnapshot snapshot;

  @override
  State<HistorySpaceDetailScreen> createState() =>
      _HistorySpaceDetailScreenState();
}

class _HistorySpaceDetailScreenState extends State<HistorySpaceDetailScreen> {
  late HistorySpaceSnapshot _snapshot = widget.snapshot;
  bool _busy = false;
  final Set<String> _expandedHours = {};

  Future<void> _reload() async {
    final spaces = await widget.server.historySpaces();
    for (final snapshot in spaces) {
      if (snapshot.space.id == _snapshot.space.id) {
        if (mounted) setState(() => _snapshot = snapshot);
        return;
      }
    }
    if (mounted) popLinkNest(context);
  }

  Future<void> _delete(Set<String> ids, String message) async {
    if (_busy || _snapshot.isActive) return;
    final confirmed = await showLinkNestDialog<bool>(
      context: context,
      builder: (context) => LinkNestDialog(
        title: '确认删除',
        actions: [
          LinkNestButton(
            label: '取消',
            variant: FButtonVariant.secondary,
            onPressed: () => popLinkNest(context, false),
          ),
          LinkNestButton(
            label: '删除',
            variant: FButtonVariant.destructive,
            onPressed: () => popLinkNest(context, true),
          ),
        ],
        child: Text(message),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    debugPrint(
      '[LinkNest] 开始删除历史文件 spaceId=${_snapshot.space.id} fileCount=${ids.length}',
    );
    try {
      await widget.server.deleteHistoryFiles(_snapshot.space.id, ids);
      debugPrint(
        '[LinkNest] 历史文件删除完成 spaceId=${_snapshot.space.id} fileCount=${ids.length}',
      );
      await _reload();
    } catch (error) {
      debugPrint('[LinkNest] 历史文件删除失败 reason=${error.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupByDate(_snapshot.files);
    return LinkNestPage(
      title: _snapshot.space.name,
      child: _snapshot.files.isEmpty
          ? const Center(child: Text('空间中没有文件'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_snapshot.isActive)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: LinkNestNotice(message: '该空间正在共享，可以查看，但不能删除。'),
                  ),
                for (final dateEntry in groups.entries)
                  _buildDateGroup(dateEntry.key, dateEntry.value),
              ],
            ),
    );
  }

  Widget _buildDateGroup(String date, List<FileRecord> files) {
    final hours = _groupByHour(files);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LinkNestSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: FAccordion(
          key: ValueKey(date),
          style: _historyAccordionStyle,
          children: [
            FAccordionItem(
              initiallyExpanded: true,
              title: Text('$date · ${files.length} 个文件'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_snapshot.isActive) ...[
                    LinkNestAction(
                      label: '删除当天文件',
                      icon: FLucideIcons.trash2,
                      onPressed: _busy
                          ? null
                          : () => _delete(
                              files.map((file) => file.id).toSet(),
                              '将永久删除 $date 的 ${files.length} 个文件。',
                            ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final hourEntry in hours.entries)
                    FAccordion(
                      key: ValueKey('$date:${hourEntry.key}'),
                      style: _historyAccordionStyle,
                      control: FAccordionControl.lifted(
                        expanded: (_) =>
                            _expandedHours.contains('$date:${hourEntry.key}'),
                        onChange: (_, expanded) {
                          setState(() {
                            if (expanded) {
                              _expandedHours.add('$date:${hourEntry.key}');
                            } else {
                              _expandedHours.remove('$date:${hourEntry.key}');
                            }
                          });
                        },
                      ),
                      children: [
                        FAccordionItem(
                          title: Text(
                            '${hourEntry.key} · ${hourEntry.value.length} 个文件',
                          ),
                          child: Column(
                            children: [
                              for (final file in hourEntry.value)
                                _buildFile(file),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFile(FileRecord file) {
    final location = file.photoLocation?.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: FutureBuilder<Uint8List>(
                    future: widget.server.historyThumbnail(file.id),
                    builder: (context, snapshot) {
                      final bytes = snapshot.data;
                      if (bytes != null && bytes.isNotEmpty) {
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        );
                      }
                      return ColoredBox(
                        color: context.theme.colors.muted,
                        child: Icon(
                          file.kind == 'video'
                              ? FLucideIcons.film
                              : FLucideIcons.image,
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      style: context.theme.typography.body.sm.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_time(file.uploadedAt.toLocal())} · ${_bytes(file.size)}'
                      '${location == null || location.isEmpty ? '' : ' · $location'}',
                      style: context.theme.typography.body.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_snapshot.isActive) ...[
                const SizedBox(width: 4),
                FButton.icon(
                  variant: FButtonVariant.ghost,
                  semanticsLabel: '删除文件',
                  semanticsTooltip: '删除文件',
                  onPress: _busy
                      ? null
                      : () => _delete({file.id}, '将永久删除“${file.name}”。'),
                  child: const Icon(FLucideIcons.trash2, size: 18),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

Map<String, List<FileRecord>> _groupByDate(List<FileRecord> files) {
  final sorted = [...files]
    ..sort((left, right) => right.uploadedAt.compareTo(left.uploadedAt));
  final groups = <String, List<FileRecord>>{};
  for (final file in sorted) {
    final local = file.uploadedAt.toLocal();
    final key = '${local.year}年${_two(local.month)}月${_two(local.day)}日';
    groups.putIfAbsent(key, () => []).add(file);
  }
  return groups;
}

Map<String, List<FileRecord>> _groupByHour(List<FileRecord> files) {
  final groups = <String, List<FileRecord>>{};
  for (final file in files) {
    final local = file.uploadedAt.toLocal();
    final key = '${_two(local.hour)}:00–${_two(local.hour)}:59';
    groups.putIfAbsent(key, () => []).add(file);
  }
  return groups;
}

String _dateTime(DateTime value) =>
    '${value.year}-${_two(value.month)}-${_two(value.day)} '
    '${_two(value.hour)}:${_two(value.minute)}';

String _time(DateTime value) => '${_two(value.hour)}:${_two(value.minute)}';

String _two(int value) => value.toString().padLeft(2, '0');

String _bytes(int value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '$value B';
}
