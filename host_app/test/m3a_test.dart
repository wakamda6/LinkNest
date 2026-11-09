import 'package:linknest/app_identity.dart';
import 'package:linknest/guest_api_client.dart';
import 'package:linknest/space_invite.dart';

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/index_store.dart';
import 'package:linknest/media_format.dart';
import 'package:linknest/native.dart';
import 'package:linknest/server.dart';
import 'package:linknest/settings_state.dart';
import 'package:linknest/space_data_source.dart';
import 'package:linknest/upload_policy.dart';

void main() {
  test('REQ-1205 publishes and refreshes a 10/8 Host invitation', () async {
    final root = await Directory.systemTemp.createTemp('linknest-network-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    await server.start(
      port: 0,
      newSpaceName: '测试',
      selectedAddress: '10.0.0.1',
    );
    expect(Uri.parse(server.inviteUrl).host, '10.0.0.1');
    await server.refreshNetworkAddresses(selectedAddress: '10.0.0.2');
    expect(Uri.parse(server.inviteUrl).host, '10.0.0.2');
  });

  test(
    'REQ-1019 discovery probe checks the active session without joining',
    () async {
      final root = await Directory.systemTemp.createTemp('linknest-discovery-');
      final server = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
        rootDirectory: root,
      );
      addTearDown(() async {
        await server.stop();
        await root.delete(recursive: true);
      });
      final url = await server.start(port: 0, newSpaceName: '局域网测试');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse('$url/api/discovery'),
      )).close();
      expect(response.statusCode, HttpStatus.ok);
      final data = jsonDecode(await utf8.decoder.bind(response).join())['data'];
      expect(data['spaceId'], server.activeSpace!.id);
      expect(data['sessionId'], isNotEmpty);
      expect(data['spaceName'], '局域网测试');
      expect(server.onlineCount, 0);
    },
  );

  test('REQ-1203 identity and nicknames survive Host restart without merging same-IP guests', () async {
    final root = await Directory.systemTemp.createTemp('linknest-identity-');
    final hostId = 'a' * 64;
    final guestId = 'b' * 64;
    LinkNestServer makeServer() => LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
      installationId: hostId,
    );
    var server = makeServer();
    var url = await server.start(port: 0, newSpaceName: '旅行');
    final clients = <GuestApiClient>[];
    GuestApiClient client(String identity) {
      final result = GuestApiClient(
        invite: SpaceInvite(
          baseUri: Uri.parse('$url/'),
          token: _tokenFrom(server.inviteUrl),
        ),
        installationId: identity,
      );
      clients.add(result);
      return result;
    }

    addTearDown(() async {
      for (final c in clients) {
        c.close();
      }
      await server.stop();
      await root.delete(recursive: true);
    });
    final guest = client(guestId);
    final handshakes = await Future.wait([
      guest.handshake(),
      guest.handshake(),
      client('c' * 64).handshake(),
    ]);
    final original = handshakes.first;
    expect(handshakes[1].visitorName, original.visitorName);
    expect(handshakes[2].visitorName, isNot(original.visitorName));
    expect(
      original.uploaderId,
      AppIdentity.forSpace(original.spaceId, guestId),
    );
    expect(original.uploaderId, isNot(guestId));
    final photo = File('${root.path}/guest.jpg')
      ..writeAsStringSync('guest-image');
    final uploaded = (await guest.uploadFile(
      photo,
      name: 'guest.jpg',
      uploader: '伪造名称',
    )).single;
    expect(uploaded.uploader, original.visitorName);
    expect(uploaded.uploaderId, original.uploaderId);
    final video = File('${root.path}/guest.mov')
      ..writeAsStringSync('paired-video');
    final live = (await guest.uploadLivePhoto(
      photo,
      video,
      photoName: 'live.jpg',
      pairedVideoName: 'live.mov',
      uploader: '伪造名称',
    )).single;
    expect(live.uploaderId, original.uploaderId);
    final hostFile = File('${root.path}/host.jpg')
      ..writeAsStringSync('host-image');
    final hostRecord = await server.importFile(hostFile, 'host.jpg', '发起者');
    expect(hostRecord!.uploaderId, server.hostUploaderId);
    expect(hostRecord.uploaderId, isNot(original.uploaderId));
    final legacy = await _upload(
      url,
      'legacy-image',
      _tokenFrom(server.inviteUrl),
    );
    expect(legacy.statusCode, 200);
    await legacy.drain<void>();
    expect(
      (await guest.listFiles()).where((f) => f.uploaderId.isEmpty),
      hasLength(1),
    );
    await server.renameActiveSpace('改名后的旅行');
    await server.stop();
    server = makeServer();
    url = await server.start(port: 0, resumeSpaceId: original.spaceId);
    final returned = client(guestId);
    final restored = await returned.handshake();
    expect(restored.visitorName, original.visitorName);
    expect(restored.uploaderId, original.uploaderId);
    expect(restored.sessionId, isNot(original.sessionId));
    expect(restored.spaceName, '改名后的旅行');
    final records = await returned.listFiles();
    expect(
      records.where((f) => f.uploaderId == original.uploaderId),
      hasLength(2),
    );
    expect(
      records.singleWhere((f) => f.id == hostRecord.id).uploaderId,
      server.hostUploaderId,
    );
    expect(
      jsonEncode(records.map((f) => f.toPublicJson()).toList()),
      isNot(contains(guestId)),
    );
    await server.stop();
    url = await server.start(port: 0, newSpaceName: '另一次旅行');
    expect(
      (await client(guestId).handshake()).uploaderId,
      isNot(original.uploaderId),
    );
  });

  group('media formats', () {
    test('uses one v1 MIME mapping', () {
      expect(MediaFormats.ofName('a.HEIF').mimeType, 'image/heif');
      expect(MediaFormats.ofName('a.tiff').mimeType, 'image/tiff');
      expect(MediaFormats.ofName('a.mov').mimeType, 'video/quicktime');
      expect(MediaFormats.ofName('a.avi').mimeType, 'video/x-msvideo');
      expect(MediaFormats.ofName('a.mpg').mimeType, 'video/mpeg');
    });

    test('does not trust an incompatible multipart type', () {
      final format = MediaFormats.resolve(
        'photo.jpg',
        declaredMimeType: 'video/mp4',
      );
      expect(format.kind, 'image');
      expect(format.mimeType, 'image/jpeg');
    });

    test('does not infer an unknown extension from multipart metadata', () {
      final format = MediaFormats.resolve(
        'payload.bin',
        declaredMimeType: 'image/jpeg',
      );
      expect(format.kind, 'other');
      expect(format.mimeType, 'application/octet-stream');
      expect(format.previewSupported, isFalse);
    });

    test('marks transfer-only formats unsupported', () {
      expect(MediaFormats.ofName('photo.bmp').previewSupported, isFalse);
      expect(MediaFormats.ofName('clip.mkv').previewSupported, isFalse);
      expect(MediaFormats.ofName('clip.mp4').previewSupported, isTrue);
      expect(
        MediaFormats.ofName('photo.bmp').supportLevel,
        MediaSupportLevel.transferOnly,
      );
      expect(MediaFormats.ofName('clip.mkv').isAcceptedMedia, isTrue);
      expect(MediaFormats.ofName('document.pdf').isAcceptedMedia, isFalse);
    });
  });

  group('native save results', () {
    test('parses structured platform results', () {
      final result = NativeSaveResult.fromChannel({
        'status': 'permissionDenied',
        'message': 'permission denied',
        'savedCount': 0,
      });

      expect(result.status, NativeSaveStatus.permissionDenied);
      expect(result.message, 'permission denied');
      expect(result.savedCount, 0);
      expect(result.succeeded, isFalse);
    });

    test('keeps compatibility with legacy boolean results', () {
      final result = NativeSaveResult.fromChannel(true);

      expect(result.status, NativeSaveStatus.saved);
      expect(result.savedCount, 1);
      expect(result.succeeded, isTrue);
    });
  });

  test('old FileRecord JSON migrates media metadata', () {
    final record = FileRecord.fromJson({
      'id': '1',
      'name': 'a.jpg',
      'size': 10,
      'kind': 'image',
      'uploader': '访客',
      'sha256': 'abc',
      'uploadedAt': 0,
    });
    expect(record.mimeType, 'image/jpeg');
    expect(record.previewStatus, PreviewStatus.unknown);
    expect(record.hasThumb, isTrue);
    expect(record.toJson()['mimeType'], 'image/jpeg');
  });

  test('Live Photo record round-trips both original resources', () {
    final record = FileRecord(
      id: 'live-1',
      name: 'IMG_0001.HEIC',
      size: 30,
      kind: 'image',
      mimeType: 'image/heic',
      previewStatus: PreviewStatus.unknown,
      uploader: '访客',
      sha256: '',
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(1),
      photoResource: const MediaResource(
        name: 'IMG_0001.HEIC',
        size: 10,
        mimeType: 'image/heic',
        sha256: 'photo-sha',
      ),
      pairedVideo: const MediaResource(
        name: 'IMG_0001.MOV',
        size: 20,
        mimeType: 'video/quicktime',
        sha256: 'video-sha',
      ),
    );

    final restored = FileRecord.fromJson(record.toJson());

    expect(restored.isLivePhoto, isTrue);
    expect(restored.size, 30);
    expect(restored.primaryResource.sha256, 'photo-sha');
    expect(restored.pairedVideo!.sha256, 'video-sha');
    expect(restored.toJson()['mediaType'], 'livePhoto');
  });

  group('upload policy', () {
    const policy = UploadPolicy(maxFileBytes: 100, reserveBytes: 20);

    test('returns 413 semantics for a file over the limit', () {
      expect(
        () => policy.checkSize(101),
        throwsA(isA<UploadFailure>().having((e) => e.status, 'status', 413)),
      );
    });

    test('returns 507 semantics when reserve cannot be retained', () {
      expect(
        () => policy.checkAvailable(30, incomingBytes: 11),
        throwsA(isA<UploadFailure>().having((e) => e.status, 'status', 507)),
      );
    });

    test('limits the complete request and file count independently', () {
      const bounded = UploadPolicy(maxRequestBytes: 100, maxFilesPerRequest: 2);
      expect(
        () => bounded.checkRequestSize(101),
        throwsA(
          isA<UploadFailure>().having(
            (e) => e.code,
            'code',
            'REQUEST_TOO_LARGE',
          ),
        ),
      );
      expect(
        () => bounded.checkFileCount(3),
        throwsA(
          isA<UploadFailure>().having((e) => e.code, 'code', 'TOO_MANY_FILES'),
        ),
      );
    });

    test('rejects non-media names before staging', () {
      expect(() => policy.checkMediaName('photo.jpg'), returnsNormally);
      expect(() => policy.checkMediaName('clip.mkv'), returnsNormally);
      expect(
        () => policy.checkMediaName('archive.zip'),
        throwsA(
          isA<UploadFailure>()
              .having((e) => e.status, 'status', 415)
              .having((e) => e.code, 'code', 'UNSUPPORTED_MEDIA_TYPE'),
        ),
      );
    });
  });

  test('IndexStore replaces and reloads a complete index', () async {
    final root = await Directory.systemTemp.createTemp('linknest-index-test-');
    addTearDown(() => root.delete(recursive: true));
    final store = IndexStore(root);
    FileRecord record(String id) => FileRecord(
      id: id,
      name: '$id.jpg',
      size: 10,
      kind: 'image',
      mimeType: 'image/jpeg',
      previewStatus: PreviewStatus.unknown,
      uploader: '访客',
      sha256: id,
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await store.save([record('1')]);
    await store.save([record('1'), record('2')]);
    final loaded = await store.load();
    expect(loaded.map((e) => e['id']), ['1', '2']);
    expect(File('${root.path}/index.json.tmp').existsSync(), isFalse);
    expect(File('${root.path}/index.json.bak').existsSync(), isFalse);
  });

  test('AsyncMutex serializes index transactions', () async {
    final mutex = AsyncMutex();
    final order = <String>[];
    final first = mutex.protect(() async {
      order.add('first-start');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      order.add('first-end');
    });
    final second = mutex.protect(() async {
      order.add('second');
    });
    await Future.wait([first, second]);
    expect(order, ['first-start', 'first-end', 'second']);
  });

  test('server creates, finds, and resumes a recent named space', () async {
    final root = await Directory.systemTemp.createTemp(
      'linknest-space-resume-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final first = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
    );
    await first.start(port: 0, newSpaceName: '杭州三日游');
    final original = first.activeSpace!;
    final originalToken = _tokenFrom(first.inviteUrl);
    await first.stop();

    final second = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
    );
    final recent = await second.recentSpace(
      now: original.lastActivityAt.add(const Duration(hours: 71)),
    );
    final expired = await second.recentSpace(
      now: original.lastActivityAt.add(const Duration(hours: 73)),
    );

    expect(recent?.id, original.id);
    expect(expired, isNull);
    await second.start(port: 0, resumeSpaceId: original.id);
    expect(second.activeSpace?.id, original.id);
    expect(second.activeSpace?.name, '杭州三日游');
    expect(_tokenFrom(second.inviteUrl), originalToken);
    await second.stop();
  });

  test(
    'server rejects a blank name and creates a distinct new space',
    () async {
      final root = await Directory.systemTemp.createTemp('linknest-new-space-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final first = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      await expectLater(
        first.start(port: 0, newSpaceName: '   '),
        throwsArgumentError,
      );
      await first.start(port: 0, newSpaceName: '第一次旅行');
      final firstId = first.activeSpace!.id;
      final firstToken = _tokenFrom(first.inviteUrl);
      await first.stop();

      final second = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      await second.start(port: 0, newSpaceName: '第二次旅行');

      expect(second.activeSpace?.id, isNot(firstId));
      expect(second.activeSpace?.name, '第二次旅行');
      expect(_tokenFrom(second.inviteUrl), isNot(firstToken));
      await second.stop();
    },
  );

  test(
    'server keeps older spaces available after newer spaces are created',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'linknest-available-spaces-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final first = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      await first.start(port: 0, newSpaceName: '空间 A');
      final spaceA = first.activeSpace!;
      await first.stop();

      final second = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      await second.start(port: 0, newSpaceName: '空间 B');
      final spaceB = second.activeSpace!;
      await second.stop();

      final third = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      final spaces = await third.availableSpaces();
      expect(spaces.map((space) => space.id), [spaceB.id, spaceA.id]);

      await third.start(port: 0, resumeSpaceId: spaceA.id);
      expect(third.activeSpace?.id, spaceA.id);
      expect(third.activeSpace?.name, '空间 A');
      await third.stop();
    },
  );

  test('AsyncLimiter bounds concurrent native work', () async {
    final limiter = AsyncLimiter(2);
    var active = 0;
    var peak = 0;
    Future<void> task() => limiter.protect(() async {
      active++;
      peak = active > peak ? active : peak;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
    });

    await Future.wait([task(), task(), task(), task()]);

    expect(peak, 2);
    expect(active, 0);
  });

  test(
    'server publishes protocol v4 identity and removes stale partial uploads',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'linknest-server-test-',
      );
      final incoming = Directory('${root.path}/incoming')..createSync();
      final stale = File('${incoming.path}/stale.part')
        ..writeAsStringSync('partial');
      final server = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      final url = await server.start(port: 0);
      addTearDown(() async {
        await server.stop();
        await root.delete(recursive: true);
      });

      final token = _tokenFrom(server.inviteUrl);
      final request = await HttpClient().getUrl(Uri.parse('$url/api/meta'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      expect(body['data']['protocolVersion'], 4);
      expect(body['data']['spaceId'], isNotEmpty);
      expect(body['data']['sessionId'], isNotEmpty);
      expect(body['data']['spaceUpdatedAt'], isA<int>());
      expect(body['data']['hostVersion'], 'test-version');
      expect(body['data']['capabilities'], contains('mediaMetadataV1'));
      expect(body['data']['capabilities'], contains('livePhotoV1'));
      expect(body['data']['capabilities'], contains('spaceIdentityV1'));
      expect(stale.existsSync(), isFalse);
    },
  );

  test(
    'active space rename updates metadata and persists to history',
    () async {
      final originalSpaceName = spaceName.value;
      final root = await Directory.systemTemp.createTemp(
        'linknest-rename-test-',
      );
      final server = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      final url = await server.start(port: 0, newSpaceName: '旧名称');
      addTearDown(() async {
        await server.stop();
        spaceName.value = originalSpaceName;
        if (await root.exists()) await root.delete(recursive: true);
      });

      final renamed = await server.renameActiveSpace(' 新名称 ');
      expect(renamed.name, '新名称');
      expect(server.activeSpace?.name, '新名称');

      final request = await HttpClient().getUrl(Uri.parse('$url/api/meta'));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_tokenFrom(server.inviteUrl)}',
      );
      final response = await request.close();
      final body =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      expect(body['data']['spaceName'], '新名称');

      await server.stop();
      final reopened = LinkNestServer(
        native: _FakeNative(availableBytes: 1024 * 1024),
        rootDirectory: root,
      );
      expect((await reopened.availableSpaces()).single.name, '新名称');
    },
  );

  test('upload endpoint returns stable 413 and cleans its part file', () async {
    final root = await Directory.systemTemp.createTemp('linknest-413-test-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
      uploadPolicy: const UploadPolicy(maxFileBytes: 4, reserveBytes: 20),
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });

    final response = await _upload(url, '12345', _tokenFrom(server.inviteUrl));
    final body =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    expect(response.statusCode, 413);
    expect(body['code'], 'FILE_TOO_LARGE');
    expect(body['error'], isNotEmpty);
    expect(Directory('${root.path}/incoming').listSync(), isEmpty);
  });

  test('upload endpoint returns stable 507 before writing', () async {
    final root = await Directory.systemTemp.createTemp('linknest-507-test-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 10),
      rootDirectory: root,
      uploadPolicy: const UploadPolicy(maxFileBytes: 100, reserveBytes: 20),
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });

    final response = await _upload(url, '1', _tokenFrom(server.inviteUrl));
    final body =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    expect(response.statusCode, 507);
    expect(body['code'], 'INSUFFICIENT_STORAGE');
    expect(body['error'], isNotEmpty);
  });

  test('upload endpoint rejects non-media before staging', () async {
    final root = await Directory.systemTemp.createTemp('linknest-415-test-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });

    final response = await _upload(
      url,
      'not a media file',
      _tokenFrom(server.inviteUrl),
      filename: 'document.pdf',
    );
    final body =
        jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    expect(response.statusCode, 415);
    expect(body['code'], 'UNSUPPORTED_MEDIA_TYPE');
    expect(Directory('${root.path}/incoming').listSync(), isEmpty);
    expect(server.files, isEmpty);
  });

  test('API requires a token and Web can exchange it for a session', () async {
    final root = await Directory.systemTemp.createTemp('linknest-auth-test-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });

    final unauthorized = await HttpClient()
        .getUrl(Uri.parse('$url/api/meta'))
        .then((request) => request.close());
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    await unauthorized.drain<void>();

    final sessionRequest = await HttpClient().postUrl(
      Uri.parse('$url/api/web-session'),
    );
    sessionRequest.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_tokenFrom(server.inviteUrl)}',
    );
    final sessionResponse = await sessionRequest.close();
    expect(sessionResponse.statusCode, HttpStatus.ok);
    expect(sessionResponse.cookies.single.name, 'linknest_session');
    final cookie = sessionResponse.cookies.single;
    await sessionResponse.drain<void>();

    final metaRequest = await HttpClient().getUrl(Uri.parse('$url/api/meta'));
    metaRequest.cookies.add(cookie);
    final metaResponse = await metaRequest.close();
    expect(metaResponse.statusCode, HttpStatus.ok);
    await metaResponse.drain<void>();
  });

  test('startup recovers a transaction and quarantines an orphan', () async {
    final root = await Directory.systemTemp.createTemp('linknest-recovery-');
    final files = Directory('${root.path}/files')..createSync();
    final transactions = Directory('${root.path}/transactions')..createSync();
    File('${files.path}/recovered').writeAsStringSync('image');
    File('${files.path}/orphan').writeAsStringSync('orphan');
    final recovered = FileRecord(
      id: 'recovered',
      name: 'recovered.jpg',
      size: 5,
      kind: 'image',
      mimeType: 'image/jpeg',
      previewStatus: PreviewStatus.unknown,
      uploader: '访客',
      sha256: 'recovered-sha',
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
    File('${transactions.path}/recovered.json')
        .writeAsStringSync(jsonEncode(recovered.toJson()));

    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024),
      rootDirectory: root,
    );
    await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });

    expect(server.files.map((record) => record.id), contains('recovered'));
    expect(File('${transactions.path}/recovered.json').existsSync(), isFalse);
    expect(File('${files.path}/orphan').existsSync(), isFalse);
    expect(
      Directory('${root.path}/lost+found')
          .listSync()
          .whereType<File>()
          .any((file) => file.path.contains('orphan')),
      isTrue,
    );
  });

  test('local import keeps picker source when index commit fails', () async {
    final root = await Directory.systemTemp.createTemp(
      'linknest-local-import-failure-',
    );
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    await File('${root.path}/state.json').delete();
    final blockedStatePath = Directory('${root.path}/state.json')..createSync();
    final source = File('${root.path}/picked.jpg')..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      server.importFile(source, 'picked.jpg', '发起者'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.exists(), isTrue);
    expect(server.files, isEmpty);
    await blockedStatePath.delete();
  });

  test('local import cancellation keeps source and removes staging', () async {
    final root = await Directory.systemTemp.createTemp(
      'linknest-local-import-cancel-',
    );
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    final source = File('${root.path}/picked.jpg')
      ..writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 1));
    var cancellationChecks = 0;

    await expectLater(
      server.importFile(
        source,
        'picked.jpg',
        '发起者',
        checkCancelled: () {
          cancellationChecks++;
          if (cancellationChecks >= 4) {
            throw const SpaceTransferCancelledException();
          }
        },
      ),
      throwsA(isA<SpaceTransferCancelledException>()),
    );

    expect(await source.exists(), isTrue);
    expect(server.files, isEmpty);
    expect(Directory('${root.path}/incoming').listSync(), isEmpty);
  });

  test('local Live Photo import commits and exposes both resources', () async {
    final root = await Directory.systemTemp.createTemp(
      'linknest-live-photo-import-',
    );
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    final photo = File('${root.path}/picked.heic')..writeAsBytesSync([1, 2]);
    final video = File('${root.path}/picked.mov')..writeAsBytesSync([3, 4, 5]);

    final record = await server.importLivePhoto(
      photo,
      'IMG_0001.HEIC',
      video,
      'IMG_0001.MOV',
      '发起者',
    );

    expect(record, isNotNull);
    expect(record!.isLivePhoto, isTrue);
    expect(record.size, 5);
    expect(await File(server.filePath(record.id)).readAsBytes(), [1, 2]);
    expect(await File(server.pairedVideoPath(record.id)).readAsBytes(), [
      3,
      4,
      5,
    ]);
    expect(photo.existsSync(), isFalse);
    expect(video.existsSync(), isFalse);

    final listRequest = await HttpClient().getUrl(Uri.parse('$url/api/files'));
    listRequest.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_tokenFrom(server.inviteUrl)}',
    );
    final listResponse = await listRequest.close();
    final listBody = jsonDecode(await utf8.decoder.bind(listResponse).join());
    final publicRecord = (listBody['data'] as List).single as Map;
    expect(publicRecord, isNot(contains('spaceId')));
    expect(publicRecord, isNot(contains('sessionId')));
    expect(publicRecord, isNot(contains('accessKey')));

    final request = await HttpClient().getUrl(
      Uri.parse('$url/api/files/${record.id}/download?resource=pairedVideo'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_tokenFrom(server.inviteUrl)}',
    );
    final response = await request.close();
    expect(response.headers.contentType!.mimeType, 'video/quicktime');
    expect(
      await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      [3, 4, 5],
    );
  });

  test('preview cache is validated and generated once per target', () async {
    final root = await Directory.systemTemp.createTemp('linknest-preview-');
    final native = _FakeNative(availableBytes: 1024 * 1024 * 1024);
    final server = LinkNestServer(native: native, rootDirectory: root);
    await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    final source = File('${root.path}/source.jpg')..writeAsStringSync('image');
    final record = await server.importFile(source, 'source.jpg', '发起者');
    final cache = File('${root.path}/thumbs/${record!.id}.jpg')
      ..writeAsStringSync('broken');

    final results = await Future.wait([
      server.thumbnail(record.id),
      server.thumbnail(record.id),
    ]);

    expect(results.every((bytes) => bytes.length == 6), isTrue);
    expect(native.thumbnailCalls, 1);
    expect(await cache.readAsBytes(), native.thumbnailBytes);
    expect(
      Directory('${root.path}/thumbs')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('download response safely encodes the original filename', () async {
    final root = await Directory.systemTemp.createTemp('linknest-filename-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    final url = await server.start(port: 0);
    addTearDown(() async {
      await server.stop();
      await root.delete(recursive: true);
    });
    final source = File('${root.path}/source.jpg')..writeAsStringSync('image');
    final record = await server.importFile(source, '中文"名称.jpg', '发起者');
    final request = await HttpClient().getUrl(
      Uri.parse('$url/api/files/${record!.id}/download'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_tokenFrom(server.inviteUrl)}',
    );
    final response = await request.close();
    final disposition = response.headers.value('content-disposition')!;
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.ok);
    expect(disposition, isNot(contains('\r')));
    expect(disposition, isNot(contains('\n')));
    expect(disposition, contains('%22'));
    expect(disposition, contains('filename*=UTF-8'));
  });

  test('video download supports HEAD and single HTTP byte ranges', () async {
    final root = await Directory.systemTemp.createTemp('linknest-range-');
    final server = LinkNestServer(
      native: _FakeNative(availableBytes: 1024 * 1024 * 1024),
      rootDirectory: root,
    );
    final url = await server.start(port: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
      await root.delete(recursive: true);
    });
    final source = File('${root.path}/source.mp4')
      ..writeAsStringSync('0123456789');
    final record = await server.importFile(source, 'clip.mp4', '发起者');
    final uri = Uri.parse('$url/api/files/${record!.id}/download');
    final token = _tokenFrom(server.inviteUrl);

    Future<HttpClientResponse> request(
      String method, {
      String? range,
      String? ifRange,
    }) async {
      final value = await client.openUrl(method, uri);
      value.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (range != null) value.headers.set('range', range);
      if (ifRange != null) value.headers.set('if-range', ifRange);
      return value.close();
    }

    final head = await request('HEAD');
    await head.drain<void>();
    expect(head.statusCode, HttpStatus.ok);
    expect(head.contentLength, 10);
    expect(head.headers.value('accept-ranges'), 'bytes');

    final partial = await request('GET', range: 'bytes=2-5');
    final partialBytes = await partial.fold<List<int>>(
      <int>[],
      (result, chunk) => result..addAll(chunk),
    );
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(partial.headers.value('content-range'), 'bytes 2-5/10');
    expect(partial.contentLength, 4);
    expect(utf8.decode(partialBytes), '2345');

    final suffix = await request('GET', range: 'bytes=-3');
    final suffixBytes = await suffix.fold<List<int>>(
      <int>[],
      (result, chunk) => result..addAll(chunk),
    );
    expect(suffix.statusCode, HttpStatus.partialContent);
    expect(suffix.headers.value('content-range'), 'bytes 7-9/10');
    expect(utf8.decode(suffixBytes), '789');

    final invalid = await request('GET', range: 'bytes=20-30');
    await invalid.drain<void>();
    expect(invalid.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(invalid.headers.value('content-range'), 'bytes */10');

    final staleRange = await request(
      'GET',
      range: 'bytes=2-5',
      ifRange: '"stale"',
    );
    final fullBytes = await staleRange.fold<List<int>>(
      <int>[],
      (result, chunk) => result..addAll(chunk),
    );
    expect(staleRange.statusCode, HttpStatus.ok);
    expect(utf8.decode(fullBytes), '0123456789');
  });
}

String _tokenFrom(String inviteUrl) =>
    Uri.splitQueryString(Uri.parse(inviteUrl).fragment)['token']!;

Future<HttpClientResponse> _upload(
  String baseUrl,
  String contents,
  String token, {
  String filename = 'test.jpg',
}) async {
  const boundary = 'linknest-test-boundary';
  final request = await HttpClient().postUrl(Uri.parse('$baseUrl/api/upload'));
  request.headers.set(
    HttpHeaders.contentTypeHeader,
    'multipart/form-data; boundary=$boundary',
  );
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  request.add(
    utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
      'Content-Type: image/jpeg\r\n\r\n'
      '$contents\r\n'
      '--$boundary--\r\n',
    ),
  );
  return request.close();
}

class _FakeNative extends LinkNestNative {
  _FakeNative({required this.availableBytes});

  final int availableBytes;
  final Uint8List thumbnailBytes = Uint8List.fromList([
    0xff,
    0xd8,
    0xff,
    0xe0,
    0xff,
    0xd9,
  ]);
  int thumbnailCalls = 0;

  @override
  Future<int> getFreeDiskBytes() async => availableBytes;

  @override
  Future<String> getAppVersion() async => 'test-version';

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
  Future<String> getLocalIp() async => InternetAddress.loopbackIPv4.address;

  @override
  Future<Uint8List> makeThumbnail(
    String path, {
    String kind = '',
    int target = 512,
    String name = '',
  }) async {
    thumbnailCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return thumbnailBytes;
  }
}
