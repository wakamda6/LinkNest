import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/native.dart';
import 'package:linknest/server.dart';

void main() {
  late Directory root;
  late _HistoryNative native;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('linknest-history-');
    native = _HistoryNative();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('keeps photo location private and shows the resolved label', () async {
    final server = LinkNestServer(native: native, rootDirectory: root);
    await server.start(port: 0, newSpaceName: '旅行');
    final source = File('${root.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);
    final record = await server.importFile(source, 'photo.jpg', '发起者');

    await server.resolveHistoryLocations();
    final snapshot = (await server.historySpaces()).single;
    final resolved = snapshot.files.single;

    expect(resolved.id, record!.id);
    expect(resolved.photoLocation!.label, '浙江省 · 杭州市');
    expect(snapshot.locationLabels, ['浙江省 · 杭州市']);
    expect(resolved.toPublicJson(), isNot(contains('photoLocation')));
    expect(resolved.toStorageJson(), contains('photoLocation'));
    await server.stop();
  });

  test(
    'deletes a Live Photo as one history item after sharing stops',
    () async {
      final server = LinkNestServer(native: native, rootDirectory: root);
      await server.start(port: 0, newSpaceName: '家庭聚会');
      final photo = File('${root.path}/live.heic')..writeAsBytesSync([1, 2]);
      final video = File('${root.path}/live.mov')..writeAsBytesSync([3, 4, 5]);
      final record = await server.importLivePhoto(
        photo,
        'live.heic',
        video,
        'live.mov',
        '发起者',
      );
      final spaceId = server.activeSpace!.id;
      await server.stop();

      expect(File('${root.path}/files/${record!.id}').existsSync(), isTrue);
      expect(
        File('${root.path}/files/${record.id}.paired').existsSync(),
        isTrue,
      );
      await server.deleteHistoryFiles(spaceId, {record.id});

      expect(File('${root.path}/files/${record.id}').existsSync(), isFalse);
      expect(
        File('${root.path}/files/${record.id}.paired').existsSync(),
        isFalse,
      );
      expect((await server.historySpaces()).single.files, isEmpty);

      await server.deleteHistorySpace(spaceId);
      expect(await server.historySpaces(), isEmpty);
    },
  );

  test('rejects deletion while the space is sharing', () async {
    final server = LinkNestServer(native: native, rootDirectory: root);
    await server.start(port: 0, newSpaceName: '正在共享');
    final source = File('${root.path}/photo.jpg')..writeAsBytesSync([1]);
    final record = await server.importFile(source, 'photo.jpg', '发起者');

    await expectLater(
      server.deleteHistoryFiles(server.activeSpace!.id, {record!.id}),
      throwsStateError,
    );
    expect(File('${root.path}/files/${record.id}').existsSync(), isTrue);
    await server.stop();
  });
}

class _HistoryNative extends LinkNestNative {
  @override
  Future<int> getFreeDiskBytes() async => 1024 * 1024 * 1024;

  @override
  Future<String> getAppVersion() async => 'test';

  @override
  Future<List<Map<String, dynamic>>> getLocalAddresses({
    bool diagnostic = false,
  }) async => [
    {
      'address': InternetAddress.loopbackIPv4.address,
      'interface': 'test',
      'priority': 0,
    },
  ];

  @override
  Future<NativePhotoCoordinates?> readPhotoCoordinates(String filePath) async =>
      const NativePhotoCoordinates(30.2741, 120.1551);

  @override
  Future<String?> reverseGeocode(double latitude, double longitude) async =>
      '浙江省 · 杭州市';

  @override
  Future<Uint8List> makeThumbnail(
    String filePath, {
    String kind = '',
    int target = 512,
    String name = '',
  }) async => Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9]);
}
