import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/guest_media_cache.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linknest-media-cache-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  GuestMediaCacheKey key({
    String spaceId = 'space-1',
    String fileId = 'file-1',
    String role = 'preview',
    String digest = 'digest-1',
    String extension = 'jpg',
  }) => GuestMediaCacheKey(
    spaceId: spaceId,
    fileId: fileId,
    role: role,
    digest: digest,
    extension: extension,
  );

  Future<GuestMediaCache> open({int maximumBytes = 1024}) =>
      GuestMediaCache.open(
        rootDirectoryProvider: () async => directory,
        freeDiskBytesProvider: () async => 1024 * 1024,
        maximumBytes: maximumBytes,
        reserveFreeBytes: 0,
      );

  test(
    'persists bytes across cache instances and isolates content keys',
    () async {
      final cache = await open();
      final first = key();
      await cache.putBytes(first, Uint8List.fromList([1, 2, 3]));
      await cache.close();

      final reopened = await open();
      expect(await reopened.readBytes(first), [1, 2, 3]);
      expect(await reopened.readBytes(key(spaceId: 'space-2')), isNull);
      expect(await reopened.readBytes(key(digest: 'changed')), isNull);
      await reopened.close();
    },
  );

  test('deduplicates concurrent byte loads', () async {
    final cache = await open();
    var loads = 0;
    Future<Uint8List> loader() async {
      loads++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return Uint8List.fromList([4, 5, 6]);
    }

    final results = await Future.wait([
      cache.getOrPutBytes(key(), loader),
      cache.getOrPutBytes(key(), loader),
    ]);

    expect(loads, 1);
    expect(results[0], [4, 5, 6]);
    expect(results[1], [4, 5, 6]);
    await cache.close();
  });

  test('stores a Live Photo pair atomically and keeps leased files', () async {
    final cache = await open(maximumBytes: 6);
    final photo = File('${directory.path}/photo.source')
      ..writeAsBytesSync([1, 2, 3]);
    final video = File('${directory.path}/video.source')
      ..writeAsBytesSync([4, 5, 6]);
    final photoKey = key(role: 'livePhoto', digest: 'photo');
    final videoKey = key(role: 'livePairedVideo', digest: 'video');
    await cache.storeFiles({photoKey: photo, videoKey: video});

    final lease = await cache.acquireFiles([photoKey, videoKey]);
    expect(lease, isNotNull);
    expect(await lease!.files.first.readAsBytes(), [1, 2, 3]);
    expect(await lease.files.last.readAsBytes(), [4, 5, 6]);

    await expectLater(
      cache.putBytes(
        key(fileId: 'other', digest: 'other'),
        Uint8List.fromList([7, 8, 9]),
      ),
      throwsA(isA<GuestMediaCacheException>()),
    );
    await lease.release();
    await cache.putBytes(
      key(fileId: 'other', digest: 'other'),
      Uint8List.fromList([7, 8, 9]),
    );
    expect(await cache.acquireFiles([photoKey, videoKey]), isNull);
    await cache.close();
  });

  test('reconciles changed digests and deletes one space only', () async {
    final cache = await open();
    final unchanged = key(fileId: 'keep', digest: 'same');
    final stale = key(fileId: 'changed', digest: 'old');
    final otherSpace = key(spaceId: 'space-2', fileId: 'other');
    await cache.putBytes(unchanged, Uint8List.fromList([1]));
    await cache.putBytes(stale, Uint8List.fromList([2]));
    await cache.putBytes(otherSpace, Uint8List.fromList([3]));

    await cache.reconcileSpace('space-1', {
      'keep': {'same'},
      'changed': {'new'},
    });
    expect(await cache.readBytes(unchanged), [1]);
    expect(await cache.readBytes(stale), isNull);
    expect(await cache.readBytes(otherSpace), [3]);

    await cache.deleteSpace('space-1');
    expect(await cache.readBytes(unchanged), isNull);
    expect(await cache.readBytes(otherSpace), [3]);
    await cache.close();
  });

  test('drops a corrupt index without exposing orphaned bytes', () async {
    final cache = await open();
    await cache.putBytes(key(), Uint8List.fromList([1, 2, 3]));
    final root = cache.root;
    await cache.close();
    await File('${root.path}${Platform.pathSeparator}index.json')
        .writeAsString('{broken', flush: true);

    final reopened = await open();
    expect(await reopened.readBytes(key()), isNull);
    final files = await reopened.root
        .list()
        .where((item) => item is File)
        .toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('index.json'));
    await reopened.close();
  });

  test('uses the confirmed 4 GiB budget and 1 GiB reserve defaults', () {
    expect(GuestMediaCache.defaultMaximumBytes, 4 * 1024 * 1024 * 1024);
    expect(GuestMediaCache.defaultReserveFreeBytes, 1024 * 1024 * 1024);
  });

  test('migrates v1 images while removing old videoBlock entries', () async {
    var cache = await open();
    final imageKey = key();
    final blockKey = key(
      fileId: 'video',
      role: 'videoBlock:0',
      digest: 'video',
      extension: '',
    );
    await cache.putBytes(imageKey, Uint8List.fromList([1, 2, 3]));
    await cache.putBytes(blockKey, Uint8List.fromList([4, 5, 6]));
    final indexFile = File(
      '${cache.root.path}${Platform.pathSeparator}index.json',
    );
    await cache.close();
    final index =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    index['version'] = 1;
    index.remove('videos');
    await indexFile.writeAsString(jsonEncode(index), flush: true);

    cache = await open();
    expect(await cache.readBytes(imageKey), [1, 2, 3]);
    expect(await cache.readBytes(blockKey), isNull);
    final dataFiles = await cache.root
        .list()
        .where((item) => item is File && !item.path.endsWith('index.json'))
        .toList();
    expect(dataFiles, hasLength(1));
    await cache.close();
  });

  test('migrates v2 entries while removing contiguous video caches', () async {
    var cache = await open();
    final imageKey = key();
    final videoKey = key(
      fileId: 'video',
      role: 'video',
      digest: 'video',
      extension: 'mp4',
    );
    await cache.putBytes(imageKey, Uint8List.fromList([1, 2, 3]));
    final indexFile = File(
      '${cache.root.path}${Platform.pathSeparator}index.json',
    );
    final videoFile = File(
      '${cache.root.path}${Platform.pathSeparator}${videoKey.id}.mp4',
    );
    await videoFile.writeAsBytes([4, 5, 6, 7], flush: true);
    await cache.close();

    final index =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    index['version'] = 2;
    index['videos'] = [
      {
        'id': videoKey.id,
        'spaceId': 'space-1',
        'fileId': 'video',
        'role': 'video',
        'digest': 'video',
        'relativePath': '${videoKey.id}.mp4',
        'declaredSize': 4,
        'blockBytes': 4,
        'bitmap': 'AQ==',
        'complete': true,
        'lastAccessedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    ];
    await indexFile.writeAsString(jsonEncode(index), flush: true);

    cache = await open();
    expect(await cache.readBytes(imageKey), [1, 2, 3]);
    expect(await videoFile.exists(), isFalse);
    final migrated =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    expect(migrated['version'], GuestMediaCache.indexVersion);
    expect(migrated.containsKey('videos'), isFalse);
    await cache.close();
  });
}
