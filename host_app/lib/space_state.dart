import 'file_record.dart';

class SharingSessionEndReason {
  static const stopped = 'stopped';
  static const interrupted = 'interrupted';
  static const migrated = 'migrated';

  static bool isValid(String value) =>
      value == stopped || value == interrupted || value == migrated;
}

class Space {
  const Space({
    required this.id,
    required this.name,
    required this.accessKey,
    required this.createdAt,
    required this.lastActivityAt,
    required this.updatedAt,
    this.participantNames = const {},
  });

  factory Space.fromJson(Map<dynamic, dynamic> json) => Space(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    accessKey: json['accessKey']?.toString() ?? '',
    createdAt: _date(json['createdAt']),
    lastActivityAt: _date(json['lastActivityAt']),
    updatedAt: _date(json['updatedAt']),
    participantNames: json['participantNames'] == null
        ? const {}
        : Map<String, String>.unmodifiable(
            Map<String, String>.from(json['participantNames'] as Map),
          ),
  );

  final String id;
  final String name;
  final String accessKey;
  final DateTime createdAt;
  final DateTime lastActivityAt;
  final DateTime updatedAt;
  final Map<String, String> participantNames;

  Space copyWith({
    String? name,
    DateTime? lastActivityAt,
    DateTime? updatedAt,
    Map<String, String>? participantNames,
  }) => Space(
    id: id,
    name: name ?? this.name,
    accessKey: accessKey,
    createdAt: createdAt,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    updatedAt: updatedAt ?? this.updatedAt,
    participantNames: participantNames ?? this.participantNames,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'accessKey': accessKey,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'lastActivityAt': lastActivityAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (participantNames.isNotEmpty) 'participantNames': participantNames,
  };
}

class SharingSession {
  const SharingSession({
    required this.id,
    required this.spaceId,
    required this.startedAt,
    this.endedAt,
    this.endReason,
  });

  factory SharingSession.fromJson(Map<dynamic, dynamic> json) {
    final rawEndedAt = json['endedAt'];
    final rawEndReason = json['endReason']?.toString();
    return SharingSession(
      id: json['id']?.toString() ?? '',
      spaceId: json['spaceId']?.toString() ?? '',
      startedAt: _date(json['startedAt']),
      endedAt: rawEndedAt == null ? null : _date(rawEndedAt),
      endReason: rawEndReason == null || rawEndReason.isEmpty
          ? null
          : rawEndReason,
    );
  }

  final String id;
  final String spaceId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? endReason;

  bool get isOpen => endedAt == null;

  SharingSession close(DateTime endedAt, String endReason) => SharingSession(
    id: id,
    spaceId: spaceId,
    startedAt: startedAt,
    endedAt: endedAt,
    endReason: endReason,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'spaceId': spaceId,
    'startedAt': startedAt.millisecondsSinceEpoch,
    if (endedAt != null) 'endedAt': endedAt!.millisecondsSinceEpoch,
    if (endReason != null) 'endReason': endReason,
  };
}

class LinkNestState {
  const LinkNestState({
    required this.spaces,
    required this.sessions,
    required this.files,
  });

  static const int currentSchemaVersion = 1;

  factory LinkNestState.empty() =>
      const LinkNestState(spaces: [], sessions: [], files: []);

  factory LinkNestState.fromJson(Map<dynamic, dynamic> json) {
    final schemaVersion = (json['schemaVersion'] as num?)?.toInt();
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException('unsupported state schema: $schemaVersion');
    }
    final state = LinkNestState(
      spaces: _maps(json['spaces']).map(Space.fromJson).toList(),
      sessions: _maps(json['sessions']).map(SharingSession.fromJson).toList(),
      files: _maps(json['files']).map(FileRecord.fromJson).toList(),
    );
    state.validate();
    return state;
  }

  final List<Space> spaces;
  final List<SharingSession> sessions;
  final List<FileRecord> files;

  Map<String, dynamic> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'spaces': spaces.map((space) => space.toJson()).toList(),
    'sessions': sessions.map((session) => session.toJson()).toList(),
    'files': files.map((file) => file.toStorageJson()).toList(),
  };

  void validate() {
    final spaceIds = <String>{};
    for (final space in spaces) {
      if (space.id.isEmpty ||
          space.name.trim().isEmpty ||
          space.accessKey.isEmpty ||
          !spaceIds.add(space.id)) {
        throw const FormatException('invalid or duplicate space');
      }
      if (space.lastActivityAt.isBefore(space.createdAt)) {
        throw const FormatException('space activity predates creation');
      }
    }

    final sessionIds = <String>{};
    for (final session in sessions) {
      if (session.id.isEmpty ||
          !sessionIds.add(session.id) ||
          !spaceIds.contains(session.spaceId)) {
        throw const FormatException('invalid sharing session');
      }
      if ((session.endedAt == null) != (session.endReason == null)) {
        throw const FormatException('incomplete sharing session closure');
      }
      if (session.endedAt != null &&
          session.endedAt!.isBefore(session.startedAt)) {
        throw const FormatException('sharing session ends before it starts');
      }
      if (session.endReason != null &&
          !SharingSessionEndReason.isValid(session.endReason!)) {
        throw const FormatException('invalid sharing session end reason');
      }
    }

    final fileIds = <String>{};
    final sessionsById = {for (final session in sessions) session.id: session};
    for (final file in files) {
      if (file.id.isEmpty ||
          !fileIds.add(file.id) ||
          !spaceIds.contains(file.spaceId) ||
          !sessionsById.containsKey(file.sessionId)) {
        throw const FormatException('invalid file ownership');
      }
      final session = sessionsById[file.sessionId]!;
      if (session.spaceId != file.spaceId) {
        throw const FormatException('file session belongs to another space');
      }
    }
  }
}

DateTime _date(Object? value) {
  if (value is! num) throw const FormatException('invalid timestamp');
  return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
}

List<Map<dynamic, dynamic>> _maps(Object? value) {
  if (value is! List) throw const FormatException('expected list');
  return value.map((item) {
    if (item is! Map) throw const FormatException('expected object');
    return item;
  }).toList();
}
