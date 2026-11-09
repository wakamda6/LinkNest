import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'file_record.dart';
import 'device_name.dart';
import 'index_store.dart';
import 'space_state.dart';

class SpaceStateStore {
  SpaceStateStore(this.root);

  final Directory root;

  File get stateFile => File('${root.path}/state.json');
  File get _temporary => File('${root.path}/state.json.tmp');
  File get _backup => File('${root.path}/state.json.bak');

  Future<bool> exists() async =>
      await stateFile.exists() || await _backup.exists();

  Future<LinkNestState> load() async {
    if (!await stateFile.exists() && await _backup.exists()) {
      await _backup.rename(stateFile.path);
    } else if (await stateFile.exists() && await _backup.exists()) {
      await _backup.delete();
    }
    if (await _temporary.exists()) await _temporary.delete();
    if (!await stateFile.exists()) return LinkNestState.empty();

    final decoded = jsonDecode(await stateFile.readAsString());
    if (decoded is! Map) {
      throw const FormatException('state.json must contain an object');
    }
    return LinkNestState.fromJson(decoded);
  }

  Future<void> save(LinkNestState state) async {
    state.validate();
    await _temporary.writeAsString(jsonEncode(state.toJson()), flush: true);

    if (!Platform.isWindows || !await stateFile.exists()) {
      await _temporary.rename(stateFile.path);
      return;
    }

    if (await _backup.exists()) await _backup.delete();
    await stateFile.rename(_backup.path);
    try {
      await _temporary.rename(stateFile.path);
      try {
        await _backup.delete();
      } catch (_) {
        // state.json 已完整替换；残留备份在下次启动时清理。
      }
    } catch (_) {
      if (!await stateFile.exists() && await _backup.exists()) {
        await _backup.rename(stateFile.path);
      }
      rethrow;
    }
  }
}

class SpaceRepository {
  SpaceRepository._(
    this.root,
    this._store,
    this._state, {
    required this._now,
    required this._idGenerator,
    required this._accessKeyGenerator,
  });

  final Directory root;
  final SpaceStateStore _store;
  final DateTime Function() _now;
  final String Function(String prefix) _idGenerator;
  final String Function() _accessKeyGenerator;
  LinkNestState _state;

  static Future<SpaceRepository> open(
    Directory root, {
    DateTime Function()? now,
    String Function(String prefix)? idGenerator,
    String Function()? accessKeyGenerator,
  }) async {
    await root.create(recursive: true);
    final clock = now ?? () => DateTime.now().toUtc();
    final ids = idGenerator ?? _secureId;
    final keys = accessKeyGenerator ?? _secureAccessKey;
    final store = SpaceStateStore(root);

    late LinkNestState state;
    if (await store.exists()) {
      state = await store.load();
    } else {
      state = await _migrateLegacyIndex(root, ids, keys);
      await store.save(state);
      await _archiveLegacyIndex(root);
    }

    final repository = SpaceRepository._(
      root,
      store,
      state,
      now: clock,
      idGenerator: ids,
      accessKeyGenerator: keys,
    );
    await repository._closeInterruptedSessions();
    return repository;
  }

  LinkNestState get state => _state;
  List<Space> get spaces => List.unmodifiable(_state.spaces);
  List<Space> get spacesByRecentActivity {
    final values = [..._state.spaces]
      ..sort(
        (left, right) => right.lastActivityAt.compareTo(left.lastActivityAt),
      );
    return List.unmodifiable(values);
  }

  List<SharingSession> get sessions => List.unmodifiable(_state.sessions);
  List<FileRecord> get files => List.unmodifiable(_state.files);

  Space? get latestSpace {
    if (_state.spaces.isEmpty) return null;
    return _state.spaces.reduce(
      (left, right) =>
          left.lastActivityAt.isAfter(right.lastActivityAt) ? left : right,
    );
  }

  Space? findSpace(String spaceId) {
    for (final space in _state.spaces) {
      if (space.id == spaceId) return space;
    }
    return null;
  }

  FileRecord? findFile(String fileId) {
    for (final file in _state.files) {
      if (file.id == fileId) return file;
    }
    return null;
  }

  List<FileRecord> filesForSpace(String spaceId) => List.unmodifiable(
    _state.files.where((record) => record.spaceId == spaceId),
  );

  /// 调用方使用索引锁串行化，与文件提交/删除共享一次原子状态写入。
  Future<String> resolveParticipantName(
    String spaceId,
    String participantId,
  ) async {
    final space = findSpace(spaceId);
    if (space == null || participantId.isEmpty) {
      throw StateError('invalid participant');
    }
    final existing = space.participantNames[participantId];
    if (existing != null) return existing;
    final used = {...space.participantNames.values, '发起者'};
    final base = generateVisitorName();
    var name = base;
    var suffix = 2;
    while (used.contains(name)) {
      name = '$base ${suffix++}';
    }
    final updated = space.copyWith(
      participantNames: Map.unmodifiable({
        ...space.participantNames,
        participantId: name,
      }),
    );
    await _save(
      LinkNestState(
        spaces: [
          for (final item in _state.spaces) item.id == spaceId ? updated : item,
        ],
        sessions: _state.sessions,
        files: _state.files,
      ),
    );
    debugPrint(
      '[LinkNest] 已保存空间内访客身份 count=${updated.participantNames.length}',
    );
    return name;
  }

  Future<Space> createSpace(String name, {DateTime? at}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    final timestamp = (at ?? _now()).toUtc();
    final space = Space(
      id: _idGenerator('space'),
      name: trimmed,
      accessKey: _accessKeyGenerator(),
      createdAt: timestamp,
      lastActivityAt: timestamp,
      updatedAt: timestamp,
    );
    await _save(
      LinkNestState(
        spaces: [..._state.spaces, space],
        sessions: _state.sessions,
        files: _state.files,
      ),
    );
    debugPrint('[LinkNest] 已创建空间 id=${space.id}');
    return space;
  }

  Future<Space> renameSpace(String spaceId, String name, {DateTime? at}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
    final index = _state.spaces.indexWhere((space) => space.id == spaceId);
    if (index < 0) {
      throw ArgumentError.value(spaceId, 'spaceId', 'does not exist');
    }
    final current = _state.spaces[index];
    if (current.name == trimmed) return current;

    final spaces = [..._state.spaces];
    final renamed = current.copyWith(
      name: trimmed,
      updatedAt: (at ?? _now()).toUtc(),
    );
    spaces[index] = renamed;
    await _save(
      LinkNestState(
        spaces: spaces,
        sessions: _state.sessions,
        files: _state.files,
      ),
    );
    debugPrint('[LinkNest] 已修改空间名称 id=$spaceId');
    return renamed;
  }

  Future<SharingSession> startSession(String spaceId, {DateTime? at}) async {
    if (!_state.spaces.any((space) => space.id == spaceId)) {
      throw ArgumentError.value(spaceId, 'spaceId', 'does not exist');
    }
    if (_state.sessions.any((session) => session.isOpen)) {
      throw StateError('a sharing session is already open');
    }
    final timestamp = (at ?? _now()).toUtc();
    final session = SharingSession(
      id: _idGenerator('session'),
      spaceId: spaceId,
      startedAt: timestamp,
    );
    await _save(
      LinkNestState(
        spaces: _updateSpaceActivity(_state.spaces, spaceId, timestamp),
        sessions: [..._state.sessions, session],
        files: _state.files,
      ),
    );
    debugPrint('[LinkNest] 已开始共享 sessionId=${session.id} spaceId=$spaceId');
    return session;
  }

  Future<void> endSession(
    String sessionId,
    String reason, {
    DateTime? at,
  }) async {
    if (!SharingSessionEndReason.isValid(reason)) {
      throw ArgumentError.value(reason, 'reason', 'is invalid');
    }
    final index = _state.sessions.indexWhere(
      (session) => session.id == sessionId,
    );
    if (index < 0) {
      throw ArgumentError.value(sessionId, 'sessionId', 'does not exist');
    }
    final current = _state.sessions[index];
    if (!current.isOpen) return;
    final requestedAt = (at ?? _now()).toUtc();
    final timestamp = requestedAt.isBefore(current.startedAt)
        ? current.startedAt
        : requestedAt;
    final sessions = [..._state.sessions];
    sessions[index] = current.close(timestamp, reason);
    await _save(
      LinkNestState(
        spaces: _updateSpaceActivity(_state.spaces, current.spaceId, timestamp),
        sessions: sessions,
        files: _state.files,
      ),
    );
    debugPrint('[LinkNest] 共享会话已结束 sessionId=$sessionId reason=$reason');
  }

  Future<void> addFile(FileRecord record) async {
    if (_state.files.any((candidate) => candidate.id == record.id)) {
      throw StateError('file id already exists: ${record.id}');
    }
    await _save(
      LinkNestState(
        spaces: _updateSpaceActivity(
          _state.spaces,
          record.spaceId,
          record.uploadedAt.toUtc(),
        ),
        sessions: _state.sessions,
        files: [..._state.files, record],
      ),
    );
  }

  Future<void> replaceFile(FileRecord record) async {
    final index = _state.files.indexWhere(
      (candidate) => candidate.id == record.id,
    );
    if (index < 0) throw StateError('file does not exist: ${record.id}');
    final files = [..._state.files];
    files[index] = record;
    await _save(
      LinkNestState(
        spaces: _state.spaces,
        sessions: _state.sessions,
        files: files,
      ),
    );
  }

  Future<void> replaceFiles(Iterable<FileRecord> replacements) async {
    final byId = {for (final record in replacements) record.id: record};
    if (byId.isEmpty) return;
    final knownIds = _state.files.map((record) => record.id).toSet();
    final missing = byId.keys.where((id) => !knownIds.contains(id));
    if (missing.isNotEmpty) {
      throw StateError('file does not exist: ${missing.first}');
    }
    final files = _state.files
        .map((record) => byId[record.id] ?? record)
        .toList();
    await _save(
      LinkNestState(
        spaces: _state.spaces,
        sessions: _state.sessions,
        files: files,
      ),
    );
  }

  Future<void> removeFiles(Set<String> fileIds) async {
    if (fileIds.isEmpty) return;
    final knownIds = _state.files.map((record) => record.id).toSet();
    final missing = fileIds.where((id) => !knownIds.contains(id));
    if (missing.isNotEmpty) {
      throw StateError('file does not exist: ${missing.first}');
    }
    await _save(
      LinkNestState(
        spaces: _state.spaces,
        sessions: _state.sessions,
        files: _state.files
            .where((record) => !fileIds.contains(record.id))
            .toList(),
      ),
    );
  }

  Future<void> removeSpace(String spaceId) async {
    if (!_state.spaces.any((space) => space.id == spaceId)) {
      throw StateError('space does not exist: $spaceId');
    }
    if (_state.sessions.any(
      (session) => session.spaceId == spaceId && session.isOpen,
    )) {
      throw StateError('active space cannot be deleted');
    }
    await _save(
      LinkNestState(
        spaces: _state.spaces.where((space) => space.id != spaceId).toList(),
        sessions: _state.sessions
            .where((session) => session.spaceId != spaceId)
            .toList(),
        files: _state.files
            .where((record) => record.spaceId != spaceId)
            .toList(),
      ),
    );
  }

  Future<void> _closeInterruptedSessions() async {
    final openSessions = _state.sessions.where((session) => session.isOpen);
    if (openSessions.isEmpty) return;
    final timestamp = _now().toUtc();
    var spaces = _state.spaces;
    final sessions = _state.sessions.map((session) {
      if (!session.isOpen) return session;
      final endedAt = timestamp.isBefore(session.startedAt)
          ? session.startedAt
          : timestamp;
      spaces = _updateSpaceActivity(spaces, session.spaceId, endedAt);
      return session.close(endedAt, SharingSessionEndReason.interrupted);
    }).toList();
    await _save(
      LinkNestState(spaces: spaces, sessions: sessions, files: _state.files),
    );
    debugPrint('[LinkNest] 已恢复异常中断会话 count=${openSessions.length}');
  }

  Future<void> _save(LinkNestState next) async {
    await _store.save(next);
    _state = next;
    debugPrint(
      '[LinkNest] 空间索引已持久化 spaces=${next.spaces.length} '
      'sessions=${next.sessions.length} files=${next.files.length}',
    );
  }

  static List<Space> _updateSpaceActivity(
    List<Space> spaces,
    String spaceId,
    DateTime activity,
  ) => spaces.map((space) {
    if (space.id != spaceId) return space;
    final timestamp = activity.toUtc();
    final lastActivity = timestamp.isAfter(space.lastActivityAt)
        ? timestamp
        : space.lastActivityAt;
    return space.copyWith(lastActivityAt: lastActivity, updatedAt: timestamp);
  }).toList();

  static Future<LinkNestState> _migrateLegacyIndex(
    Directory root,
    String Function(String prefix) idGenerator,
    String Function() accessKeyGenerator,
  ) async {
    final legacyFile = File('${root.path}/index.json');
    final legacyBackup = File('${root.path}/index.json.bak');
    if (!await legacyFile.exists() && !await legacyBackup.exists()) {
      return LinkNestState.empty();
    }

    final raw = await IndexStore(root).load();
    if (raw.isEmpty) return LinkNestState.empty();
    final records = raw.map(FileRecord.fromJson).toList();
    for (final record in records) {
      if (!await File('${root.path}/files/${record.id}').exists()) {
        throw FormatException('legacy media is missing: ${record.id}');
      }
      if (record.isLivePhoto &&
          !await File('${root.path}/files/${record.id}.paired').exists()) {
        throw FormatException(
          'legacy Live Photo video is missing: ${record.id}',
        );
      }
    }

    final uploaded = records.map((record) => record.uploadedAt.toUtc()).toList()
      ..sort();
    final createdAt = uploaded.first;
    final lastActivityAt = uploaded.last;
    final spaceId = idGenerator('space');
    final sessionId = idGenerator('session');
    final migratedFiles = records
        .map(
          (record) => record.copyWith(spaceId: spaceId, sessionId: sessionId),
        )
        .toList();
    final state = LinkNestState(
      spaces: [
        Space(
          id: spaceId,
          name: '旧版空间',
          accessKey: accessKeyGenerator(),
          createdAt: createdAt,
          lastActivityAt: lastActivityAt,
          updatedAt: lastActivityAt,
        ),
      ],
      sessions: [
        SharingSession(
          id: sessionId,
          spaceId: spaceId,
          startedAt: createdAt,
          endedAt: lastActivityAt,
          endReason: SharingSessionEndReason.migrated,
        ),
      ],
      files: migratedFiles,
    );
    state.validate();
    debugPrint('[LinkNest] 已迁移旧版索引 records=${records.length}');
    return state;
  }

  static Future<void> _archiveLegacyIndex(Directory root) async {
    final legacy = File('${root.path}/index.json');
    if (!await legacy.exists()) return;
    try {
      final directory = Directory('${root.path}/migration');
      await directory.create(recursive: true);
      final destination = File('${directory.path}/legacy-index.json');
      if (await destination.exists()) await destination.delete();
      await legacy.rename(destination.path);
      debugPrint('[LinkNest] 已归档旧版索引 directory=migration');
    } catch (error) {
      // state.json 已提交成功；保留旧索引不会影响后续启动。
      debugPrint('[LinkNest] 归档旧版索引失败 reason=${error.runtimeType}');
    }
  }

  static String _secureId(String prefix) => '$prefix-${_randomToken(12)}';
  static String _secureAccessKey() => _randomToken(32);

  static String _randomToken(int byteCount) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
