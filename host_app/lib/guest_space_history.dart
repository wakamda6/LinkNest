import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'guest_media_cache.dart';
import 'space_invite.dart';

typedef GuestSpaceCacheRemover = Future<void> Function(String spaceId);

class RecentGuestSpace {
  const RecentGuestSpace({
    required this.spaceId,
    required this.name,
    required this.inviteUrl,
    required this.lastJoinedAt,
  });

  factory RecentGuestSpace.fromJson(Map<dynamic, dynamic> json) {
    final record = RecentGuestSpace(
      spaceId: json['spaceId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      inviteUrl: json['inviteUrl']?.toString() ?? '',
      lastJoinedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['lastJoinedAt'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
    );
    record.validate();
    return record;
  }

  final String spaceId;
  final String name;
  final String inviteUrl;
  final DateTime lastJoinedAt;

  SpaceInvite get invite => SpaceInvite.parse(inviteUrl);

  Map<String, Object> toJson() => {
    'spaceId': spaceId,
    'name': name,
    'inviteUrl': inviteUrl,
    'lastJoinedAt': lastJoinedAt.toUtc().millisecondsSinceEpoch,
  };

  void validate() {
    if (spaceId.isEmpty || name.trim().isEmpty) {
      throw const FormatException('最近空间记录不完整');
    }
    SpaceInvite.parse(inviteUrl);
  }
}

class GuestSpaceHistory {
  GuestSpaceHistory._(this._preferences, this._spaces, this._cacheRemover);

  static const String _storageKey = 'guest_recent_spaces_v1';

  final SharedPreferences _preferences;
  final GuestSpaceCacheRemover _cacheRemover;
  List<RecentGuestSpace> _spaces;

  List<RecentGuestSpace> get spaces => List.unmodifiable(_spaces);

  static Future<GuestSpaceHistory> open({
    SharedPreferences? preferences,
    GuestSpaceCacheRemover? cacheRemover,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final removeCache =
        cacheRemover ?? GuestMediaCache.removeSpaceFromDefaultCache;
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return GuestSpaceHistory._(prefs, [], removeCache);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('最近空间不是数组');
      final spaces = <RecentGuestSpace>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          spaces.add(RecentGuestSpace.fromJson(item));
        } on FormatException {
          // 单条旧记录或损坏记录不影响其余历史空间。
        }
      }
      spaces.sort((a, b) => b.lastJoinedAt.compareTo(a.lastJoinedAt));
      return GuestSpaceHistory._(prefs, spaces, removeCache);
    } catch (error) {
      debugPrint('[LinkNest] 已忽略最近访客空间记录 reason=${error.runtimeType}');
      return GuestSpaceHistory._(prefs, [], removeCache);
    }
  }

  /// 移除本机参与记录和该空间的 App 私有性能缓存，不访问 Host 或系统相册。
  Future<void> remove(String spaceId) async {
    // 删除前读当前记录，避免旧页面实例覆盖后来保存的其他空间。
    final latest = await GuestSpaceHistory.open(
      preferences: _preferences,
      cacheRemover: _cacheRemover,
    );
    final remaining = latest.spaces
        .where((space) => space.spaceId != spaceId)
        .toList();
    if (remaining.length == latest.spaces.length) {
      _spaces = remaining;
      return;
    }
    await _cacheRemover(spaceId);
    try {
      final saved = await _preferences.setString(
        _storageKey,
        jsonEncode(remaining.map((space) => space.toJson()).toList()),
      );
      if (!saved) throw StateError('参与记录保存失败');
    } catch (_) {
      // SharedPreferences 会先更新缓存；失败时重新读取，避免界面误认为删除成功。
      await _preferences.reload();
      rethrow;
    }
    _spaces = remaining;
    debugPrint('[LinkNest] 已删除本机参与记录 remaining=${remaining.length}');
  }

  Future<void> remember({
    required String spaceId,
    required String name,
    required SpaceInvite invite,
    DateTime? joinedAt,
  }) async {
    final record = RecentGuestSpace(
      spaceId: spaceId,
      name: name.trim(),
      inviteUrl: invite.url,
      lastJoinedAt: (joinedAt ?? DateTime.now()).toUtc(),
    );
    record.validate();
    _spaces = [
      record,
      ..._spaces.where((candidate) => candidate.spaceId != spaceId),
    ];
    await _preferences.setString(
      _storageKey,
      jsonEncode(_spaces.map((space) => space.toJson()).toList()),
    );
    debugPrint('[LinkNest] 已记住访客空间 id=$spaceId');
  }
}
