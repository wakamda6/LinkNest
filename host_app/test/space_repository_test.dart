import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/file_record.dart';
import 'package:linknest/space_repository.dart';
import 'package:linknest/space_state.dart';

void main() {
  late Directory root;
  var sequence = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linknest-space-state-');
    sequence = 0;
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<SpaceRepository> openAt(DateTime now) => SpaceRepository.open(
    root,
    now: () => now,
    idGenerator: (prefix) => '$prefix-${sequence++}',
    accessKeyGenerator: () => 'stable-access-key',
  );

  test(
    'persists spaces, sessions, file ownership, and private fields',
    () async {
      final now = DateTime.utc(2026, 9, 23, 10);
      final repository = await openAt(now);
      final space = await repository.createSpace('杭州三日游');
      final session = await repository.startSession(space.id);
      final record = _record(
        id: 'photo-1',
        uploadedAt: now.add(const Duration(minutes: 1)),
        spaceId: space.id,
        sessionId: session.id,
      );

      await repository.addFile(record);
      await repository.endSession(
        session.id,
        SharingSessionEndReason.stopped,
        at: now.add(const Duration(minutes: 2)),
      );

      final publicJson = record.toPublicJson();
      expect(publicJson, isNot(contains('spaceId')));
      expect(publicJson, isNot(contains('sessionId')));
      expect(publicJson, isNot(contains('accessKey')));

      final decoded = jsonDecode(
        await File('${root.path}/state.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(decoded['schemaVersion'], LinkNestState.currentSchemaVersion);
      expect(decoded['spaces'][0]['accessKey'], 'stable-access-key');
      expect(decoded['files'][0]['spaceId'], space.id);
      expect(decoded['files'][0]['sessionId'], session.id);
      expect(File('${root.path}/state.json.tmp').existsSync(), isFalse);
      expect(File('${root.path}/state.json.bak').existsSync(), isFalse);
    },
  );

  test(
    'migrates legacy ordinary and Live Photo records without moving media',
    () async {
      final files = Directory('${root.path}/files')
        ..createSync(recursive: true);
      final ordinary = _record(
        id: 'ordinary',
        uploadedAt: DateTime.utc(2026, 9, 20, 8),
      );
      final live = _liveRecord(
        id: 'live',
        uploadedAt: DateTime.utc(2026, 9, 21, 9),
      );
      await File('${files.path}/ordinary').writeAsBytes([1, 2, 3]);
      await File('${files.path}/live').writeAsBytes([4, 5]);
      await File('${files.path}/live.paired').writeAsBytes([6, 7, 8]);
      await File('${root.path}/index.json').writeAsString(
        jsonEncode([ordinary.toPublicJson(), live.toPublicJson()]),
      );

      final repository = await openAt(DateTime.utc(2026, 9, 23));

      expect(repository.spaces.single.name, '旧版空间');
      expect(
        repository.sessions.single.endReason,
        SharingSessionEndReason.migrated,
      );
      expect(repository.files, hasLength(2));
      expect(
        repository.files.every(
          (record) =>
              record.spaceId == repository.spaces.single.id &&
              record.sessionId == repository.sessions.single.id,
        ),
        isTrue,
      );
      expect(await File('${files.path}/ordinary').readAsBytes(), [1, 2, 3]);
      expect(await File('${files.path}/live').readAsBytes(), [4, 5]);
      expect(await File('${files.path}/live.paired').readAsBytes(), [6, 7, 8]);
      expect(File('${root.path}/index.json').existsSync(), isFalse);
      expect(
        File('${root.path}/migration/legacy-index.json').existsSync(),
        isTrue,
      );
    },
  );

  test('keeps the legacy index when required media is missing', () async {
    final record = _record(
      id: 'missing',
      uploadedAt: DateTime.utc(2026, 9, 20),
    );
    final legacy = File('${root.path}/index.json');
    await legacy.writeAsString(jsonEncode([record.toPublicJson()]));

    await expectLater(
      openAt(DateTime.utc(2026, 9, 23)),
      throwsA(isA<FormatException>()),
    );

    expect(await legacy.exists(), isTrue);
    expect(File('${root.path}/state.json').existsSync(), isFalse);
  });

  test('marks an open session interrupted on the next startup', () async {
    final startedAt = DateTime.utc(2026, 9, 23, 10);
    final first = await openAt(startedAt);
    final space = await first.createSpace('家庭聚会');
    final session = await first.startSession(space.id);

    final recoveredAt = startedAt.add(const Duration(hours: 1));
    final recovered = await openAt(recoveredAt);
    final restored = recovered.sessions.singleWhere(
      (candidate) => candidate.id == session.id,
    );

    expect(restored.endedAt, recoveredAt);
    expect(restored.endReason, SharingSessionEndReason.interrupted);
    expect(recovered.spaces.single.lastActivityAt, recoveredAt);
  });
}

FileRecord _record({
  required String id,
  required DateTime uploadedAt,
  String spaceId = '',
  String sessionId = '',
}) => FileRecord(
  id: id,
  name: '$id.jpg',
  size: 3,
  kind: 'image',
  mimeType: 'image/jpeg',
  previewStatus: PreviewStatus.unknown,
  uploader: '访客',
  sha256: '$id-sha',
  uploadedAt: uploadedAt,
  spaceId: spaceId,
  sessionId: sessionId,
);

FileRecord _liveRecord({required String id, required DateTime uploadedAt}) =>
    FileRecord(
      id: id,
      name: '$id.heic',
      size: 5,
      kind: 'image',
      mimeType: 'image/heic',
      previewStatus: PreviewStatus.unknown,
      uploader: '访客',
      sha256: '',
      uploadedAt: uploadedAt,
      photoResource: const MediaResource(
        name: 'live.heic',
        size: 2,
        mimeType: 'image/heic',
        sha256: 'live-photo-sha',
      ),
      pairedVideo: const MediaResource(
        name: 'live.mov',
        size: 3,
        mimeType: 'video/quicktime',
        sha256: 'live-video-sha',
      ),
    );
