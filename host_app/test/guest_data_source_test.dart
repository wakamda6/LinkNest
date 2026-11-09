import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linknest/guest_api_client.dart';
import 'package:linknest/guest_data_source.dart';
import 'package:linknest/guest_media_cache.dart';
import 'package:linknest/guest_transfer_runtime.dart';
import 'package:linknest/file_record.dart';
import 'package:linknest/native.dart';
import 'package:linknest/protocol.dart';
import 'package:linknest/space_invite.dart';
import 'package:linknest/space_data_source.dart';

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789';
  final invite = SpaceInvite.parse('http://192.168.43.1:8080/#token=$token');
  final handshake = SpaceHandshake(
    spaceId: 'space-1',
    sessionId: 'session-1',
    spaceName: '周末聚会',
    spaceUpdatedAt: DateTime.fromMillisecondsSinceEpoch(1720000000000),
    visitorName: '访客 1',
    protocolVersion: linkNestProtocolVersion,
    hostVersion: '1.0.0+1',
    capabilities: {'thumbnail', 'preview'},
  );
  final jpeg = [0xff, 0xd8, 0xff, 0x00, 0xff, 0xd9];

  Map<String, Object?> fileJson({String id = 'file_1'}) => {
    'id': id,
    'name': 'photo.jpg',
    'size': 1234,
    'kind': 'image',
    'mimeType': 'image/jpeg',
    'previewStatus': 'ready',
    'uploader': '访客 1',
    'sha256': 'abc123',
    'uploadedAt': 1720000000000,
  };

  http.Response jsonResponse(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response handshakeResponse({String spaceId = 'space-1'}) =>
      jsonResponse({
        'ok': true,
        'data': {
          'spaceId': spaceId,
          'sessionId': 'session-reconnected',
          'spaceName': '周末聚会',
          'spaceUpdatedAt': 1720000001000,
          'visitorName': '访客 1',
          'protocolVersion': linkNestProtocolVersion,
          'hostVersion': '1.0.0+1',
          'capabilities': guestRequiredCapabilities.toList(),
        },
      });

  test('exposes full gallery capabilities and file list', () async {
    final api = GuestApiClient(
      invite: invite,
      client: MockClient(
        (_) async => jsonResponse({
          'ok': true,
          'data': [fileJson()],
        }),
      ),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    final files = await dataSource.listFiles();

    expect(dataSource.spaceName.value, '周末聚会');
    expect(dataSource.participantName, '访客 1');
    expect(dataSource.capabilities.canAddMedia, isTrue);
    expect(dataSource.capabilities.canSaveOriginals, isTrue);
    expect(files.single.id, 'file_1');
  });

  test('ordinary video playback uses the Host network source directly', () {
    final streamingHandshake = SpaceHandshake(
      spaceId: handshake.spaceId,
      sessionId: handshake.sessionId,
      spaceName: handshake.spaceName,
      spaceUpdatedAt: handshake.spaceUpdatedAt,
      visitorName: handshake.visitorName,
      protocolVersion: handshake.protocolVersion,
      hostVersion: handshake.hostVersion,
      capabilities: {...handshake.capabilities, 'videoRangeV1'},
    );
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async => http.Response('', 500)),
    );
    final dataSource = GuestDataSource(api, handshake: streamingHandshake);
    addTearDown(dataSource.close);
    final video = FileRecord.fromJson({
      ...fileJson(id: 'video-1'),
      'name': 'clip.mp4',
      'kind': 'video',
      'mimeType': 'video/mp4',
    });

    final source = dataSource.videoPlaybackSource(video);

    expect(source, isNotNull);
    expect(source!.uri.host, invite.baseUri.host);
    expect(source.uri.host, isNot(anyOf('127.0.0.1', 'localhost', '::1')));
    expect(source.headers[HttpHeaders.authorizationHeader], 'Bearer $token');
  });

  test('file polling refreshes a changed Host space name', () async {
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        if (request.url.path == '/api/meta') {
          return jsonResponse({
            'ok': true,
            'data': {
              'spaceId': 'space-1',
              'sessionId': 'session-1',
              'spaceName': '更新后的聚会',
              'spaceUpdatedAt': 1720000001000,
              'visitorName': '访客 1',
              'protocolVersion': linkNestProtocolVersion,
              'hostVersion': '1.0.0+1',
              'capabilities': guestRequiredCapabilities.toList(),
            },
          });
        }
        return jsonResponse({
          'ok': true,
          'data': [fileJson()],
        });
      }),
    );
    final dataSource = GuestDataSource(
      api,
      handshake: handshake,
      metadataRefreshInterval: Duration.zero,
    );
    addTearDown(dataSource.close);

    await dataSource.listFiles();

    expect(dataSource.spaceName.value, '更新后的聚会');
  });

  test('recognizes Android and iOS Wi-Fi interface names', () {
    expect(isLikelyWifiInterface('wlan0'), isTrue);
    expect(isLikelyWifiInterface('swlan0'), isTrue);
    expect(isLikelyWifiInterface('en0'), isTrue);
    expect(isLikelyWifiInterface('en1'), isTrue);
    expect(isLikelyWifiInterface('rmnet_data0'), isFalse);
    expect(isLikelyWifiInterface('pdp_ip0'), isFalse);
  });

  test('thumbnail cache avoids duplicate HTTP requests', () async {
    final originalDebugPrint = debugPrint;
    final logs = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    var calls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    expect(await dataSource.thumbnail('file_1'), jpeg);
    expect(await dataSource.thumbnail('file_1'), jpeg);
    expect(calls, 1);
    expect(logs.where((line) => line.contains('访客媒体读取完成')).toList(), [
      '[LinkNest] 访客媒体读取完成 '
          'id=file_1 resource=thumbnail source=host',
      '[LinkNest] 访客媒体读取完成 '
          'id=file_1 resource=thumbnail source=memory',
    ]);
    expect(logs.any((line) => line.contains('缓存未命中')), isFalse);
    expect(logs.any((line) => line.contains('复用访客媒体请求')), isFalse);
  });

  test('preview state changes retain an already loaded media cache', () async {
    var listCalls = 0;
    var thumbnailCalls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        if (request.url.path == '/api/files') {
          listCalls++;
          return jsonResponse({
            'ok': true,
            'data': [
              {
                ...fileJson(),
                'previewStatus': listCalls == 1 ? 'unknown' : 'ready',
              },
            ],
          });
        }
        thumbnailCalls++;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    await dataSource.listFiles();
    expect(await dataSource.thumbnail('file_1'), jpeg);
    await dataSource.listFiles();
    expect(await dataSource.thumbnail('file_1'), jpeg);

    expect(thumbnailCalls, 1);
  });

  test('media content changes invalidate the media cache', () async {
    var listCalls = 0;
    var thumbnailCalls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        if (request.url.path == '/api/files') {
          listCalls++;
          return jsonResponse({
            'ok': true,
            'data': [
              {
                ...fileJson(),
                'sha256': listCalls == 1 ? 'first-hash' : 'second-hash',
              },
            ],
          });
        }
        thumbnailCalls++;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    await dataSource.listFiles();
    expect(await dataSource.thumbnail('file_1'), jpeg);
    await dataSource.listFiles();
    expect(await dataSource.thumbnail('file_1'), jpeg);

    expect(thumbnailCalls, 2);
  });

  test('concurrent preview requests for one file share one request', () async {
    var calls = 0;
    final gate = Completer<void>();
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        calls++;
        await gate.future;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    final first = dataSource.preview('file_1');
    final second = dataSource.preview('file_1');
    gate.complete();

    final results = await Future.wait([first, second]);
    expect(results[0], jpeg);
    expect(results[1], jpeg);
    expect(calls, 1);
  });

  test('preview requests are limited to two concurrent HTTP calls', () async {
    var active = 0;
    var maximumActive = 0;
    final gate = Completer<void>();
    final firstTwoStarted = Completer<void>();
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        active++;
        if (active > maximumActive) maximumActive = active;
        if (active == 2 && !firstTwoStarted.isCompleted) {
          firstTwoStarted.complete();
        }
        await gate.future;
        active--;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    final requests = [
      dataSource.preview('file_1'),
      dataSource.preview('file_2'),
      dataSource.preview('file_3'),
    ];
    await firstTwoStarted.future.timeout(const Duration(seconds: 1));
    expect(maximumActive, 2);
    gate.complete();

    await Future.wait(requests);
    expect(maximumActive, 2);
  });

  test('closed data source rejects new requests', () async {
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async => http.Response('', 500)),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);

    await dataSource.close();

    await expectLater(
      dataSource.listFiles(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'DATA_SOURCE_CLOSED',
        ),
      ),
    );
  });

  test(
    'uploads sequentially and retains failed picker cache for retry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'linknest-guest-data-upload-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final files = <PickedMedia>[];
      for (var index = 0; index < 3; index++) {
        final file = File('${directory.path}/picked-$index.jpg');
        await file.writeAsBytes([index + 1]);
        files.add(PickedMedia(path: file.path, name: 'photo-$index.jpg'));
      }
      var call = 0;
      var active = 0;
      var maximumActive = 0;
      final api = GuestApiClient(
        invite: invite,
        client: MockClient((_) async {
          call++;
          active++;
          if (active > maximumActive) maximumActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          if (call == 1) {
            return jsonResponse({
              'ok': true,
              'data': [fileJson()],
            });
          }
          if (call == 2) return jsonResponse({'ok': true, 'data': []});
          return http.Response(
            jsonEncode({
              'ok': false,
              'code': 'INSUFFICIENT_STORAGE',
              'error': '设备剩余存储空间不足',
            }),
            507,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final dataSource = GuestDataSource(api, handshake: handshake);
      addTearDown(dataSource.close);
      final progress = <SpaceTransferProgress>[];

      final result = await dataSource.addPickedMedia(
        files,
        onProgress: progress.add,
      );

      expect(result.added, 1);
      expect(result.skipped, 1);
      expect(result.failed, ['photo-2.jpg']);
      expect(result.pending, 1);
      expect(result.cancelled, isFalse);
      expect(call, 3);
      expect(maximumActive, 1);
      expect(progress.map((item) => item.fileName).toSet(), {
        'photo-0.jpg',
        'photo-1.jpg',
        'photo-2.jpg',
      });
      expect(await File(files[0].path).exists(), isFalse);
      expect(await File(files[1].path).exists(), isFalse);
      expect(await File(files[2].path).exists(), isTrue);
      expect(dataSource.pendingUploadNames.value, ['photo-2.jpg']);

      await dataSource.discardPendingUploads();
      expect(await File(files[2].path).exists(), isFalse);
      expect(dataSource.pendingUploadNames.value, isEmpty);
    },
  );

  test('skips unsupported files without sending an upload request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-data-unsupported-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/document.pdf');
    await file.writeAsBytes([1, 2, 3]);
    var calls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        calls++;
        return http.Response('', 500);
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    final result = await dataSource.addPickedMedia([
      PickedMedia(path: file.path, name: 'document.pdf'),
    ]);

    expect(result.added, 0);
    expect(result.skipped, 0);
    expect(result.unsupported, ['document.pdf']);
    expect(result.failed, isEmpty);
    expect(result.pending, 0);
    expect(result.cancelled, isFalse);
    expect(calls, 0);
    expect(await file.exists(), isFalse);
  });

  test('retries a retained upload and releases its picker cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-data-retry-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1, 2, 3]);
    var call = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        call++;
        if (call == 1) {
          return http.Response(
            jsonEncode({
              'ok': false,
              'code': 'INSUFFICIENT_STORAGE',
              'error': 'storage full',
            }),
            507,
            headers: const {'content-type': 'application/json'},
          );
        }
        return jsonResponse({
          'ok': true,
          'data': [fileJson()],
        });
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);

    final first = await dataSource.addPickedMedia([
      PickedMedia(path: file.path, name: 'photo.jpg'),
    ]);
    expect(first.failed, ['photo.jpg']);
    expect(first.pending, 1);
    expect(await file.exists(), isTrue);

    final retried = await dataSource.retryPendingUploads();
    expect(retried.added, 1);
    expect(retried.pending, 0);
    expect(dataSource.pendingUploadNames.value, isEmpty);
    expect(await file.exists(), isFalse);
  });

  test('cancelled uploads remain pending until discarded', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-data-cancel-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final files = <PickedMedia>[];
    for (var index = 0; index < 2; index++) {
      final file = File('${directory.path}/picked-$index.jpg');
      await file.writeAsBytes([index + 1]);
      files.add(PickedMedia(path: file.path, name: 'photo-$index.jpg'));
    }
    var calls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        calls++;
        return jsonResponse({'ok': true, 'data': <Object>[]});
      }),
    );
    final dataSource = GuestDataSource(api, handshake: handshake);
    addTearDown(dataSource.close);
    final cancellation = SpaceTransferCancellation()..cancel();

    final result = await dataSource.addPickedMedia(
      files,
      cancellation: cancellation,
    );

    expect(result.cancelled, isTrue);
    expect(result.pending, 2);
    expect(calls, 0);
    expect(dataSource.pendingUploadNames.value, ['photo-0.jpg', 'photo-1.jpg']);
    for (final picked in files) {
      expect(await File(picked.path).exists(), isTrue);
    }

    await dataSource.discardPendingUploads();
    for (final picked in files) {
      expect(await File(picked.path).exists(), isFalse);
    }
  });

  test('background expiration cancels and retains an active upload', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-background-expiration-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1, 2, 3]);
    var calls = 0;
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async {
        calls++;
        return jsonResponse({'ok': true, 'data': <Object>[]});
      }),
    );
    final runtime = _FakeGuestTransferRuntime(expireOnStart: true);
    addTearDown(runtime.close);
    final dataSource = GuestDataSource(
      api,
      handshake: handshake,
      transferRuntime: runtime,
    );
    addTearDown(dataSource.close);

    final result = await dataSource.addPickedMedia([
      PickedMedia(path: file.path, name: 'photo.jpg'),
    ]);

    expect(result.cancelled, isTrue);
    expect(result.pending, 1);
    expect(calls, 0);
    expect(runtime.starts, 1);
    expect(runtime.stops, 1);
    expect(await file.exists(), isTrue);
    expect(dataSource.consumeBackgroundInterruptedUpload(), isTrue);
    expect(dataSource.consumeBackgroundInterruptedUpload(), isFalse);
  });

  test(
    'connection degrades, disconnects, and recovers after polling',
    () async {
      var calls = 0;
      final api = GuestApiClient(
        invite: invite,
        client: MockClient((_) async {
          calls++;
          if (calls <= 3) {
            throw http.ClientException('host unreachable');
          }
          return jsonResponse({'ok': true, 'data': <Object>[]});
        }),
      );
      final dataSource = GuestDataSource(api, handshake: handshake);
      addTearDown(dataSource.close);

      for (var attempt = 1; attempt <= 3; attempt++) {
        await expectLater(
          dataSource.listFiles(),
          throwsA(isA<GuestApiException>()),
        );
        expect(
          dataSource.connectionState.value.status,
          attempt < 3
              ? SpaceConnectionStatus.degraded
              : SpaceConnectionStatus.disconnected,
        );
      }

      await dataSource.listFiles();
      expect(
        dataSource.connectionState.value.status,
        SpaceConnectionStatus.connected,
      );
    },
  );

  test(
    'reconnect rebuilds the HTTP client even when the address is unchanged',
    () async {
      var clientsCreated = 0;
      final dataSource = GuestDataSource(
        GuestApiClient(
          invite: invite,
          client: MockClient((_) async => handshakeResponse()),
        ),
        handshake: handshake,
        clientFactory: (candidate) {
          clientsCreated++;
          return GuestApiClient(
            invite: candidate,
            client: MockClient((_) async => handshakeResponse()),
          );
        },
      );
      addTearDown(dataSource.close);

      await dataSource.reconnect();
      await dataSource.reconnect();

      expect(clientsCreated, 2);
      expect(
        dataSource.connectionState.value.status,
        SpaceConnectionStatus.connected,
      );
    },
  );

  test(
    'reconnect switches to the current Wi-Fi gateway and persists it',
    () async {
      final attemptedHosts = <String>[];
      SpaceInvite? persistedInvite;
      final dataSource = GuestDataSource(
        GuestApiClient(
          invite: invite,
          client: MockClient((_) async => handshakeResponse()),
        ),
        handshake: handshake,
        reconnectAddressProvider: () async => ['192.168.137.1'],
        clientFactory: (candidate) {
          attemptedHosts.add(candidate.baseUri.host);
          return GuestApiClient(
            invite: candidate,
            client: MockClient((request) async {
              if (candidate.baseUri.host == '192.168.43.1') {
                throw http.ClientException(
                  'old hotspot address is unreachable',
                );
              }
              if (request.url.path == '/api/meta') return handshakeResponse();
              return jsonResponse({'ok': true, 'data': <Object>[]});
            }),
          );
        },
        onInviteChanged: (_, candidate) async {
          persistedInvite = candidate;
        },
      );
      addTearDown(dataSource.close);

      await dataSource.reconnect();
      final files = await dataSource.listFiles();

      expect(attemptedHosts, ['192.168.43.1', '192.168.137.1']);
      expect(persistedInvite?.baseUri.host, '192.168.137.1');
      expect(files, isEmpty);
    },
  );

  test('reconnect rejects a gateway serving a different space', () async {
    final dataSource = GuestDataSource(
      GuestApiClient(
        invite: invite,
        client: MockClient((_) async => handshakeResponse()),
      ),
      handshake: handshake,
      reconnectAddressProvider: () async => ['192.168.137.1'],
      clientFactory: (candidate) => GuestApiClient(
        invite: candidate,
        client: MockClient((_) async {
          if (candidate.baseUri.host == '192.168.43.1') {
            throw http.ClientException('old hotspot address is unreachable');
          }
          return handshakeResponse(spaceId: 'space-2');
        }),
      ),
    );
    addTearDown(dataSource.close);

    await expectLater(
      dataSource.reconnect(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'SPACE_MISMATCH',
        ),
      ),
    );
  });

  test('materializes an original and deletes it when released', () async {
    final bytes = [1, 2, 3, 4];
    final record = FileRecord.fromJson({
      ...fileJson(),
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-materialize-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final api = GuestApiClient(
      invite: invite,
      client: MockClient(
        (_) async => http.Response.bytes(
          bytes,
          200,
          headers: const {'content-type': 'image/jpeg'},
        ),
      ),
    );
    final runtime = _FakeGuestTransferRuntime();
    addTearDown(runtime.close);
    final dataSource = GuestDataSource(
      api,
      handshake: handshake,
      temporaryDirectoryProvider: () async => directory,
      transferRuntime: runtime,
    );
    addTearDown(dataSource.close);
    final progress = <SpaceTransferProgress>[];

    final original = await dataSource.materializeOriginal(
      record,
      onProgress: progress.add,
    );

    expect(original.path, endsWith('.jpg'));
    expect(await File(original.path).readAsBytes(), bytes);
    expect(progress.first.completedBytes, 0);
    expect(progress.last.completedBytes, bytes.length);
    expect(runtime.starts, 1);
    expect(runtime.updates, greaterThan(0));
    expect(runtime.stops, 1);
    await original.dispose();
    await original.dispose();
    expect(await File(original.path).exists(), isFalse);
  });

  test('disk thumbnail cache survives data source recreation', () async {
    final originalDebugPrint = debugPrint;
    final logs = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-preview-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    Future<GuestMediaCache> openCache() => GuestMediaCache.open(
      rootDirectoryProvider: () async => directory,
      freeDiskBytesProvider: () async => 1024 * 1024,
      maximumBytes: 1024,
      reserveFreeBytes: 0,
    );

    var firstThumbnailCalls = 0;
    final firstApi = GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        if (request.url.path == '/api/files') {
          return jsonResponse({
            'ok': true,
            'data': [fileJson()],
          });
        }
        firstThumbnailCalls++;
        return http.Response.bytes(
          jpeg,
          200,
          headers: const {'content-type': 'image/jpeg'},
        );
      }),
    );
    final first = GuestDataSource(
      firstApi,
      handshake: handshake,
      mediaCache: await openCache(),
    );
    await first.listFiles();
    expect(await first.thumbnail('file_1'), jpeg);
    expect(firstThumbnailCalls, 1);
    await first.close();

    var secondThumbnailCalls = 0;
    final secondApi = GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        if (request.url.path == '/api/files') {
          return jsonResponse({
            'ok': true,
            'data': [fileJson()],
          });
        }
        secondThumbnailCalls++;
        return http.Response('', 500);
      }),
    );
    final second = GuestDataSource(
      secondApi,
      handshake: handshake,
      mediaCache: await openCache(),
    );
    await second.listFiles();
    expect(await second.thumbnail('file_1'), jpeg);
    expect(secondThumbnailCalls, 0);
    expect(
      logs,
      contains(
        '[LinkNest] 访客媒体读取完成 '
        'id=file_1 resource=thumbnail source=disk',
      ),
    );
    expect(logs.any((line) => line.contains('磁盘缓存命中')), isFalse);
    await second.close();
  });

  test('Live Photo pair remains cached after dispose and rejoin', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-live-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final photoBytes = [1, 2];
    final videoBytes = [3, 4, 5];
    final record = FileRecord(
      id: 'live-1',
      name: 'IMG_0001.HEIC',
      size: photoBytes.length + videoBytes.length,
      kind: 'image',
      mimeType: 'image/heic',
      previewStatus: PreviewStatus.ready,
      uploader: '访客 1',
      sha256: sha256.convert(photoBytes).toString(),
      uploadedAt: DateTime.utc(2026, 10, 3),
      photoResource: MediaResource(
        name: 'IMG_0001.HEIC',
        size: photoBytes.length,
        mimeType: 'image/heic',
        sha256: sha256.convert(photoBytes).toString(),
      ),
      pairedVideo: MediaResource(
        name: 'IMG_0001.MOV',
        size: videoBytes.length,
        mimeType: 'video/quicktime',
        sha256: sha256.convert(videoBytes).toString(),
      ),
    );
    Future<GuestMediaCache> openCache() => GuestMediaCache.open(
      rootDirectoryProvider: () async => directory,
      freeDiskBytesProvider: () async => 1024 * 1024,
      maximumBytes: 1024,
      reserveFreeBytes: 0,
    );

    var downloads = 0;
    GuestApiClient api() => GuestApiClient(
      invite: invite,
      client: MockClient((request) async {
        downloads++;
        final paired = request.url.queryParameters['resource'] == 'pairedVideo';
        final bytes = paired ? videoBytes : photoBytes;
        return http.Response.bytes(
          bytes,
          200,
          headers: {
            'content-type': paired ? 'video/quicktime' : 'image/heic',
            'content-length': '${bytes.length}',
          },
        );
      }),
    );

    var source = GuestDataSource(
      api(),
      handshake: handshake,
      mediaCache: await openCache(),
      temporaryDirectoryProvider: () async => directory,
    );
    final first = await source.materializeOriginal(record);
    final photoPath = first.path;
    final videoPath = first.pairedVideoPath!;
    expect(downloads, 2);
    await first.dispose();
    expect(await File(photoPath).exists(), isTrue);
    expect(await File(videoPath).exists(), isTrue);
    await source.close();

    source = GuestDataSource(
      api(),
      handshake: handshake,
      mediaCache: await openCache(),
      temporaryDirectoryProvider: () async => directory,
    );
    final second = await source.materializeOriginal(record);
    expect(downloads, 2);
    expect(await File(second.path).readAsBytes(), photoBytes);
    expect(await File(second.pairedVideoPath!).readAsBytes(), videoBytes);
    await second.dispose();
    await source.close();
  });
}

class _FakeGuestTransferRuntime implements GuestTransferRuntime {
  _FakeGuestTransferRuntime({this.expireOnStart = false});

  final bool expireOnStart;
  final StreamController<void> _expirationController =
      StreamController<void>.broadcast(sync: true);
  int starts = 0;
  int updates = 0;
  int stops = 0;

  @override
  Stream<void> get backgroundTimeExpired => _expirationController.stream;

  @override
  Future<void> start({
    required String direction,
    required String fileName,
    required int totalBytes,
  }) async {
    starts++;
    if (expireOnStart) _expirationController.add(null);
  }

  @override
  Future<void> update(
    SpaceTransferProgress progress, {
    required String direction,
  }) async {
    updates++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  Future<void> close() => _expirationController.close();
}
