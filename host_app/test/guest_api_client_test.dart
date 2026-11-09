import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linknest/file_record.dart';
import 'package:linknest/guest_api_client.dart';
import 'package:linknest/protocol.dart';
import 'package:linknest/space_data_source.dart';
import 'package:linknest/space_invite.dart';

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789';
  final invite = SpaceInvite.parse('http://192.168.43.1:8080/#token=$token');

  Map<String, Object?> successData({
    int protocolVersion = linkNestProtocolVersion,
    List<String> capabilities = linkNestCapabilities,
  }) => {
    'ok': true,
    'data': {
      'spaceId': 'space-1',
      'sessionId': 'session-1',
      'spaceName': '周末聚会',
      'spaceUpdatedAt': 1720000000000,
      'visitorName': '访客 1',
      'protocolVersion': protocolVersion,
      'hostVersion': '1.0.0+1',
      'capabilities': capabilities,
    },
  };

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

  Map<String, Object?> livePhotoJson(
    List<int> photoBytes,
    List<int> videoBytes,
  ) => {
    'id': 'live_1',
    'name': 'IMG_0001.HEIC',
    'size': photoBytes.length + videoBytes.length,
    'kind': 'image',
    'mimeType': 'image/heic',
    'previewStatus': 'ready',
    'uploader': '访客 1',
    'sha256': '',
    'uploadedAt': 1720000000000,
    'mediaType': 'livePhoto',
    'resources': {
      'photo': {
        'name': 'IMG_0001.HEIC',
        'size': photoBytes.length,
        'mimeType': 'image/heic',
        'sha256': sha256.convert(photoBytes).toString(),
      },
      'pairedVideo': {
        'name': 'IMG_0001.MOV',
        'size': videoBytes.length,
        'mimeType': 'video/quicktime',
        'sha256': sha256.convert(videoBytes).toString(),
      },
    },
  };

  FileRecord downloadRecord(List<int> bytes) => FileRecord.fromJson({
    ...fileJson(),
    'size': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  });

  http.Response jsonResponse(Object body, int statusCode) => http.Response(
    jsonEncode(body),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  test(
    'handshake sends bearer token without fragment and parses metadata',
    () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return jsonResponse(successData(), 200);
      });
      final api = GuestApiClient(invite: invite, client: client);

      final result = await api.handshake();

      expect(captured.method, 'GET');
      expect(captured.url, Uri.parse('http://192.168.43.1:8080/api/meta'));
      expect(captured.headers['Authorization'], 'Bearer $token');
      expect(captured.followRedirects, isFalse);
      expect(result.spaceName, '周末聚会');
      expect(result.spaceId, 'space-1');
      expect(result.sessionId, 'session-1');
      expect(result.protocolVersion, linkNestProtocolVersion);
    },
  );

  test('rejects incompatible protocol', () async {
    final client = MockClient(
      (_) async => jsonResponse(successData(protocolVersion: 99), 200),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'INCOMPATIBLE_PROTOCOL',
        ),
      ),
    );
  });

  test('rejects missing required capabilities', () async {
    final client = MockClient(
      (_) async => jsonResponse(
        successData(capabilities: const ['spaceTokenAuth']),
        200,
      ),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'MISSING_CAPABILITY',
        ),
      ),
    );
  });

  test('accepts a Host without the optional video range capability', () async {
    final client = MockClient(
      (_) async => jsonResponse(
        successData(capabilities: guestRequiredCapabilities),
        200,
      ),
    );
    final api = GuestApiClient(invite: invite, client: client);

    final result = await api.handshake();

    expect(result.capabilities, isNot(contains('videoRangeV1')));
  });

  test('builds an authenticated network video playback source', () {
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async => http.Response('', 500)),
    );
    final record = FileRecord.fromJson({
      ...fileJson(id: 'video_1'),
      'name': 'clip.mp4',
      'kind': 'video',
      'mimeType': 'video/mp4',
    });

    final source = api.videoPlaybackSource(record);

    expect(
      source.uri,
      Uri.parse('http://192.168.43.1:8080/api/files/video_1/download'),
    );
    expect(source.headers[HttpHeaders.authorizationHeader], 'Bearer $token');
    expect(source.headers[HttpHeaders.acceptHeader], 'video/mp4');
  });

  test('maps server error envelope', () async {
    final client = MockClient(
      (_) async => jsonResponse({
        'ok': false,
        'code': 'AUTH_REQUIRED',
        'error': '空间凭证无效或已过期',
      }, 401),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>()
            .having((error) => error.code, 'code', 'AUTH_REQUIRED')
            .having((error) => error.statusCode, 'statusCode', 401),
      ),
    );
  });

  test('does not follow redirects', () async {
    final client = MockClient(
      (_) async =>
          http.Response('', 302, headers: {'location': 'http://8.8.8.8/'}),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'UNEXPECTED_REDIRECT',
        ),
      ),
    );
  });

  test('rejects malformed success response', () async {
    final client = MockClient((_) async => http.Response('[]', 200));
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('maps malformed JSON to a protocol error', () async {
    final client = MockClient((_) async => http.Response('{', 200));
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.handshake(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('listFiles parses records and sends bearer token', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return jsonResponse({
        'ok': true,
        'data': [fileJson()],
      }, 200);
    });
    final api = GuestApiClient(invite: invite, client: client);

    final records = await api.listFiles();

    expect(captured.url.path, '/api/files');
    expect(captured.headers['Authorization'], 'Bearer $token');
    expect(records, hasLength(1));
    expect(records.single.id, 'file_1');
    expect(records.single.name, 'photo.jpg');
  });

  test('listFiles rejects incomplete records', () async {
    final invalid = fileJson()..remove('sha256');
    final client = MockClient(
      (_) async => jsonResponse({
        'ok': true,
        'data': [invalid],
      }, 200),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.listFiles(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('thumbnail accepts JPEG response', () async {
    final jpeg = [0xff, 0xd8, 0xff, 0x00, 0xff, 0xd9];
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response.bytes(
        jpeg,
        200,
        headers: const {'content-type': 'image/jpeg'},
      );
    });
    final api = GuestApiClient(invite: invite, client: client);

    final result = await api.thumbnail('file_1');

    expect(captured.url.path, '/api/files/file_1/thumbnail');
    expect(captured.headers['Authorization'], 'Bearer $token');
    expect(result, jpeg);
  });

  test('preview rejects invalid content type', () async {
    final client = MockClient(
      (_) async => http.Response.bytes(
        [0xff, 0xd8, 0xff, 0xd9],
        200,
        headers: const {'content-type': 'application/octet-stream'},
      ),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.preview('file_1'),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'INVALID_PREVIEW',
        ),
      ),
    );
  });

  test('closed client rejects new requests', () async {
    final api = GuestApiClient(
      invite: invite,
      client: MockClient((_) async => http.Response('', 500)),
    );
    api.close();

    await expectLater(
      api.listFiles(),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'CLIENT_CLOSED',
        ),
      ),
    );
  });

  test('uploadFile streams multipart data and reports file progress', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-upload-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    late http.Request captured;
    final progress = <int>[];
    final client = MockClient((request) async {
      captured = request;
      return jsonResponse({
        'ok': true,
        'data': [fileJson()],
      }, 200);
    });
    final api = GuestApiClient(invite: invite, client: client);

    final records = await api.uploadFile(
      file,
      name: 'photo.jpg',
      uploader: 'Guest 1',
      onProgress: (completed, _) => progress.add(completed),
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/upload');
    expect(captured.followRedirects, isFalse);
    expect(captured.headers['Authorization'], 'Bearer $token');
    expect(
      captured.headers['content-type'],
      startsWith('multipart/form-data;'),
    );
    final multipart = latin1.decode(captured.bodyBytes);
    expect(multipart, contains('name="uploader"'));
    expect(multipart, contains('Guest 1'));
    expect(multipart, contains('name="file"; filename="photo.jpg"'));
    expect(progress.last, 5);
    expect(records.single.id, 'file_1');
  });

  test(
    'uploadLivePhoto sends both resources in one multipart request',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'linknest-guest-live-upload-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final photoBytes = [1, 2];
      final videoBytes = [3, 4, 5];
      final photo = File('${directory.path}/IMG_0001.HEIC')
        ..writeAsBytesSync(photoBytes);
      final video = File('${directory.path}/IMG_0001.MOV')
        ..writeAsBytesSync(videoBytes);
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return jsonResponse({
          'ok': true,
          'data': [livePhotoJson(photoBytes, videoBytes)],
        }, 200);
      });
      final api = GuestApiClient(invite: invite, client: client);

      final records = await api.uploadLivePhoto(
        photo,
        video,
        photoName: 'IMG_0001.HEIC',
        pairedVideoName: 'IMG_0001.MOV',
        uploader: 'Guest 1',
      );

      final multipart = latin1.decode(captured.bodyBytes);
      expect(multipart, contains('name="photo"; filename="IMG_0001.HEIC"'));
      expect(
        multipart,
        contains('name="pairedVideo"; filename="IMG_0001.MOV"'),
      );
      expect(records.single.isLivePhoto, isTrue);
      expect(records.single.size, 5);
    },
  );

  test('uploadFile maps an empty data array to a duplicate', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-duplicate-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1]);
    final api = GuestApiClient(
      invite: invite,
      client: MockClient(
        (_) async => jsonResponse({'ok': true, 'data': []}, 200),
      ),
    );

    expect(
      await api.uploadFile(file, name: 'photo.jpg', uploader: 'Guest 1'),
      isEmpty,
    );
  });

  test('uploadFile preserves stable server error codes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-upload-error-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1]);
    final api = GuestApiClient(
      invite: invite,
      client: MockClient(
        (_) async => jsonResponse({
          'ok': false,
          'code': 'INSUFFICIENT_STORAGE',
          'error': '设备剩余存储空间不足',
        }, 507),
      ),
    );

    await expectLater(
      api.uploadFile(file, name: 'photo.jpg', uploader: 'Guest 1'),
      throwsA(
        isA<GuestApiException>()
            .having((error) => error.code, 'code', 'INSUFFICIENT_STORAGE')
            .having((error) => error.statusCode, 'statusCode', 507),
      ),
    );
  });

  test('uploadFile aborts an active multipart request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-upload-cancel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/picked.jpg');
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    final started = Completer<void>();
    final client = MockClient.streaming((request, _) async {
      final abortable = request as http.AbortableMultipartRequest;
      started.complete();
      await abortable.abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    final api = GuestApiClient(invite: invite, client: client);
    final cancellation = SpaceTransferCancellation();

    final upload = api.uploadFile(
      file,
      name: 'photo.jpg',
      uploader: 'Guest 1',
      cancellation: cancellation,
    );
    await started.future;
    cancellation.cancel();

    await expectLater(upload, throwsA(isA<SpaceTransferCancelledException>()));
  });

  test('downloadFile streams and validates the original file', () async {
    final bytes = [1, 2, 3, 4, 5];
    final record = downloadRecord(bytes);
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/file_1.jpg');
    late http.BaseRequest captured;
    final progress = <int>[];
    final client = MockClient.streaming((request, _) async {
      captured = request;
      return http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
        200,
        contentLength: bytes.length,
        headers: const {'content-type': 'image/jpeg'},
      );
    });
    final api = GuestApiClient(invite: invite, client: client);

    await api.downloadFile(
      record,
      destination,
      onProgress: (completed, _) => progress.add(completed),
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, '/api/files/file_1/download');
    expect(captured.followRedirects, isFalse);
    expect(captured.headers['Authorization'], 'Bearer $token');
    expect(await destination.readAsBytes(), bytes);
    expect(progress, [2, 5]);
    expect(await File('${destination.path}.part').exists(), isFalse);
  });

  test(
    'downloadFile selects and validates the Live Photo paired video',
    () async {
      final photoBytes = [1, 2];
      final videoBytes = [3, 4, 5];
      final record = FileRecord.fromJson(livePhotoJson(photoBytes, videoBytes));
      final directory = await Directory.systemTemp.createTemp(
        'linknest-guest-live-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/IMG_0001.MOV');
      late http.BaseRequest captured;
      final client = MockClient.streaming((request, _) async {
        captured = request;
        return http.StreamedResponse(
          Stream.value(videoBytes),
          200,
          contentLength: videoBytes.length,
          headers: const {'content-type': 'video/quicktime'},
        );
      });
      final api = GuestApiClient(invite: invite, client: client);

      await api.downloadFile(record, destination, resource: record.pairedVideo);

      expect(captured.url.queryParameters['resource'], 'pairedVideo');
      expect(await destination.readAsBytes(), videoBytes);
    },
  );

  test('downloadFile aborts and removes partial data', () async {
    final bytes = [1, 2, 3, 4, 5];
    final record = downloadRecord(bytes);
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-download-cancel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/file_1.jpg');
    final started = Completer<void>();
    final client = MockClient.streaming((request, _) async {
      final abortable = request as http.AbortableRequest;
      started.complete();
      await abortable.abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    final api = GuestApiClient(invite: invite, client: client);
    final cancellation = SpaceTransferCancellation();

    final download = api.downloadFile(
      record,
      destination,
      cancellation: cancellation,
    );
    await started.future;
    cancellation.cancel();

    await expectLater(
      download,
      throwsA(isA<SpaceTransferCancelledException>()),
    );
    expect(await destination.exists(), isFalse);
    expect(await File('${destination.path}.part').exists(), isFalse);
  });

  test('downloadFile removes partial data after a length mismatch', () async {
    final bytes = [1, 2, 3];
    final record = downloadRecord(bytes);
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-download-length-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/file_1.jpg');
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length + 1,
        headers: const {'content-type': 'image/jpeg'},
      ),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.downloadFile(record, destination),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'DOWNLOAD_LENGTH_MISMATCH',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
    expect(await File('${destination.path}.part').exists(), isFalse);
  });

  test(
    'downloadFile rejects a truncated body without content length',
    () async {
      final expectedBytes = [1, 2, 3, 4];
      final receivedBytes = [1, 2, 3];
      final record = downloadRecord(expectedBytes);
      final directory = await Directory.systemTemp.createTemp(
        'linknest-guest-download-truncated-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/file_1.jpg');
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(receivedBytes),
          200,
          headers: const {'content-type': 'image/jpeg'},
        ),
      );
      final api = GuestApiClient(invite: invite, client: client);

      await expectLater(
        api.downloadFile(record, destination),
        throwsA(
          isA<GuestApiException>().having(
            (error) => error.code,
            'code',
            'DOWNLOAD_LENGTH_MISMATCH',
          ),
        ),
      );
      expect(await destination.exists(), isFalse);
      expect(await File('${destination.path}.part').exists(), isFalse);
    },
  );

  test('downloadFile removes completed bytes after a hash mismatch', () async {
    final bytes = [1, 2, 3];
    final record = FileRecord.fromJson({
      ...fileJson(),
      'size': bytes.length,
      'sha256': 'incorrect',
    });
    final directory = await Directory.systemTemp.createTemp(
      'linknest-guest-download-hash-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/file_1.jpg');
    final client = MockClient(
      (_) async => http.Response.bytes(
        bytes,
        200,
        headers: const {'content-type': 'image/jpeg'},
      ),
    );
    final api = GuestApiClient(invite: invite, client: client);

    await expectLater(
      api.downloadFile(record, destination),
      throwsA(
        isA<GuestApiException>().having(
          (error) => error.code,
          'code',
          'DOWNLOAD_HASH_MISMATCH',
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
    expect(await File('${destination.path}.part').exists(), isFalse);
  });

  test(
    'downloadFile rejects a mismatched content type before writing',
    () async {
      final bytes = [1, 2, 3];
      final record = downloadRecord(bytes);
      final directory = await Directory.systemTemp.createTemp(
        'linknest-guest-download-mime-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/file_1.jpg');
      final client = MockClient(
        (_) async => http.Response.bytes(
          bytes,
          200,
          headers: const {'content-type': 'application/octet-stream'},
        ),
      );
      final api = GuestApiClient(invite: invite, client: client);

      await expectLater(
        api.downloadFile(record, destination),
        throwsA(
          isA<GuestApiException>().having(
            (error) => error.code,
            'code',
            'DOWNLOAD_MIME_MISMATCH',
          ),
        ),
      );
      expect(await destination.exists(), isFalse);
      expect(await File('${destination.path}.part').exists(), isFalse);
    },
  );
}
