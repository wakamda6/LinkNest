import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linknest/guest_api_client.dart';
import 'package:linknest/guest_space_history.dart';
import 'package:linknest/protocol.dart';
import 'package:linknest/space_gallery.dart';
import 'package:linknest/space_discovery.dart';
import 'package:linknest/space_invite.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/join_space.dart';
import 'package:linknest/native.dart';
import 'package:linknest/wifi_join.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wifiCode = 'WIFI:T:WPA;S:旅行热点;P:password123;;';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('discovered space opens without showing scanner: $platform', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final native = _FakeNative()..connected = true;
      final scanner = _FakeScanner();
      final previous = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = scanner;
      addTearDown(() async {
        MobileScannerPlatform.instance = previous;
        await native.events.close();
        await scanner.captures.close();
      });
      final invite = SpaceInvite.parse(
        'http://192.168.43.1:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: linkNestLightTheme,
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: linkNestLocalizations,
          builder: (_, child) => LinkNestTheme(child: child!),
          home: JoinSpaceScreen(
            native: native,
            initialSpace: DiscoveredSpace(
              spaceId: 'trip',
              name: '旅行',
              sessionId: 'session-1',
              invites: [invite],
            ),
            clientFactory: (value) => GuestApiClient(
              invite: value,
              client: MockClient((request) async {
                if (request.url.path == '/api/meta') {
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                }
                return http.Response(
                  jsonEncode({
                    'ok': true,
                    'data': request.url.path == '/api/meta'
                        ? {
                            'spaceId': 'trip',
                            'sessionId': 'session-1',
                            'spaceName': '旅行',
                            'spaceUpdatedAt': 1720000000000,
                            'visitorName': '访客',
                            'hostVersion': '1.2.0',
                            'protocolVersion': linkNestProtocolVersion,
                            'capabilities': linkNestCapabilities,
                          }
                        : [],
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.text('正在连接空间…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(SpaceGalleryScreen), findsOneWidget);
      expect(scanner.starts, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final outcome in ['wrong-space', 'unavailable', 'success']) {
    testWidgets(
      'history entry uses only saved address without camera/discovery: $outcome',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final native = _FakeNative()..connected = true;
        final scanner = _FakeScanner();
        final previous = MobileScannerPlatform.instance;
        MobileScannerPlatform.instance = scanner;
        addTearDown(() async {
          MobileScannerPlatform.instance = previous;
          await native.events.close();
          await scanner.captures.close();
        });
        final visited = <Uri>[];
        final invite = SpaceInvite.parse(
          'http://192.168.43.1:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
        );
        final record = RecentGuestSpace(
          spaceId: 'original-space',
          name: '保存的相聚',
          inviteUrl: invite.url,
          lastJoinedAt: DateTime.utc(2026, 9, 27),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: linkNestLightTheme,
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: linkNestLocalizations,
            builder: (_, child) => LinkNestTheme(child: child!),
            home: JoinSpaceScreen(
              native: native,
              historySpace: record,
              clientFactory: (savedInvite) => GuestApiClient(
                invite: savedInvite,
                client: MockClient((request) async {
                  visited.add(request.url);
                  if (outcome == 'unavailable') {
                    throw http.ClientException('offline');
                  }
                  return http.Response(
                    jsonEncode({
                      'ok': true,
                      'data': request.url.path == '/api/meta'
                          ? {
                              'spaceId': outcome == 'wrong-space'
                                  ? 'another-space'
                                  : 'original-space',
                              'sessionId': 'session-1',
                              'spaceName': '当前相聚名称',
                              'spaceUpdatedAt': 1720000000000,
                              'visitorName': '访客',
                              'hostVersion': '1.2.0',
                              'protocolVersion': linkNestProtocolVersion,
                              'capabilities': linkNestCapabilities,
                            }
                          : [],
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  );
                }),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(scanner.starts, 0);
        expect(find.byType(MobileScanner), findsNothing);
        expect(visited, isNotEmpty);
        expect(
          visited.every(
            (uri) => uri.host == '192.168.43.1' && uri.port == 8080,
          ),
          isTrue,
        );
        if (outcome == 'success') {
          expect(find.byType(SpaceGalleryScreen), findsOneWidget);
          expect(
            (await GuestSpaceHistory.open()).spaces.single.spaceId,
            'original-space',
          );
        } else {
          expect(find.byType(SpaceGalleryScreen), findsNothing);
          expect(find.text('重试连接'), findsOneWidget);
          if (outcome == 'wrong-space') {
            expect(find.textContaining('已指向其他空间'), findsOneWidget);
          }
          expect((await GuestSpaceHistory.open()).spaces, isEmpty);
          expect(visited, hasLength(1));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  group('Wi-Fi QR parsing', () {
    test('keeps Chinese, emoji, spaces and escaped credential characters', () {
      final wifi = WifiCredentials.parse(
        r'WIFI:T:WPA;S: 旅行😀\;\:\,\\\" ;P:ab\;cd\:ef\\gh;H:true;;',
      );
      expect(wifi.ssid, ' 旅行😀;:,\\" ');
      expect(wifi.password, 'ab;cd:ef\\gh');
      expect(wifi.hidden, isTrue);
      expect(wifi.toString(), isNot(contains(wifi.password)));
      expect(wifi.toString(), isNot(contains(wifi.ssid)));
    });

    test('accepts open hotspots and preserves UTF-8 SSID byte limit', () {
      expect(WifiCredentials.parse('WIFI:S:Guest;T:nopass;;').security, 'open');
      expect(
        WifiCredentials.parse('WIFI:S:${'中' * 10}ab;T:nopass;;').ssid,
        '${'中' * 10}ab',
      );
      expect(
        () => WifiCredentials.parse('WIFI:S:${'中' * 11};T:nopass;;'),
        throwsFormatException,
      );
    });

    test('rejects ambiguous, unsupported and malformed payloads', () {
      for (final input in [
        'WIFI:S:one;S:two;T:nopass;;',
        'WIFI:S:one;T:WPA2-EAP;P:password123;;',
        'WIFI:S:one;T:WPA;P:short;;',
        'WIFI:S:one;T:WPA;P:中文password;;',
        'WIFI:S:one;T:nopass;H:maybe;;',
        'WIFI:S:one\\',
        'WIFI:S:;T:nopass;;',
        'http://192.168.1.1:8080/',
      ]) {
        expect(() => WifiCredentials.parse(input), throwsFormatException);
      }
    });
  });

  group('Wi-Fi request lifecycle', () {
    test('iOS configuration stays unverified until Host handshake', () async {
      final native = _FakeNative();
      final controller = GuestWifiController(native);
      final task = controller.connect(WifiCredentials.parse(_wifiCode));
      native.finish(0, 'verificationPending');
      await task;
      expect(controller.state, WifiJoinState.verificationPending);
      expect(controller.message, contains('扫描空间码确认'));
      expect(controller.message, isNot(contains('已连接')));
      controller.confirmHostConnection();
      expect(controller.state, WifiJoinState.connected);
      await controller.release();
      controller.dispose();
    });

    test('keeps successful connection until explicit release', () async {
      final native = _FakeNative();
      final controller = GuestWifiController(native);
      final task = controller.connect(WifiCredentials.parse(_wifiCode));
      native.finish(0, 'connected');
      await task;
      expect(controller.state, WifiJoinState.connected);
      expect(native.released, isEmpty);
      await controller.release();
      expect(native.released, [native.requests.first]);
      controller.dispose();
    });

    test(
      'cancel and retry ignore old completions and old network loss',
      () async {
        final native = _FakeNative();
        final controller = GuestWifiController(native);
        final oldTask = controller.connect(WifiCredentials.parse(_wifiCode));
        await controller.cancel();
        final newTask = controller.connect(WifiCredentials.parse(_wifiCode));
        native.finish(0, 'connected');
        await oldTask;
        expect(controller.state, WifiJoinState.connecting);
        native.finish(1, 'connected');
        await newTask;
        native.events.add({
          'requestId': native.requests.first,
          'state': 'lost',
        });
        expect(controller.state, WifiJoinState.connected);
        native.events.add({'requestId': native.requests.last, 'state': 'lost'});
        expect(controller.state, WifiJoinState.disconnected);
        controller.dispose();
      },
    );

    test(
      'timeout releases native request and leaves retry available',
      () async {
        final native = _FakeNative();
        final controller = GuestWifiController(
          native,
          timeout: const Duration(milliseconds: 5),
        );
        await controller.connect(WifiCredentials.parse(_wifiCode));
        expect(controller.state, WifiJoinState.failed);
        expect(controller.message, contains('超时'));
        expect(native.released, [native.requests.single]);
        expect(controller.credentials, isNotNull);
        native.finish(0, 'connected');
        controller.dispose();
      },
    );

    test(
      'disposing before system completion releases and ignores its result',
      () async {
        final native = _FakeNative();
        final controller = GuestWifiController(native);
        final task = controller.connect(WifiCredentials.parse(_wifiCode));
        controller.dispose();
        native.finish(0, 'connected');
        await task;
        expect(native.released, [native.requests.single]);
      },
    );
  });

  testWidgets(
    'offline Guest scans Wi-Fi, recovers from rejection and cancels retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final native = _FakeNative();
      final previous = MobileScannerPlatform.instance;
      final scanner = _FakeScanner();
      MobileScannerPlatform.instance = scanner;
      addTearDown(() => MobileScannerPlatform.instance = previous);
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: linkNestLightTheme,
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: linkNestLocalizations,
          builder: (_, child) => LinkNestTheme(child: child!),
          home: JoinSpaceScreen(native: native),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MobileScanner), findsOneWidget);
      expect(scanner.starts, 1);
      scanner.scan('not-a-code');
      await tester.pump();
      scanner.scan(_wifiCode);
      await tester.pump();
      expect(native.requests, hasLength(1));
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      native.finish(0, 'unavailable');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('重试 Wi-Fi 连接'));
      await tester.pump();
      expect(native.requests, hasLength(2));
      await tester.tap(find.text('取消连接'));
      await tester.pump();
      native.finish(1, 'connected');
      await tester.pump();
      expect(find.textContaining('已取消连接'), findsOneWidget);
      expect(find.text('Wi-Fi 已连接，请继续扫描空间码'), findsNothing);
      await tester.tap(find.text('重试 Wi-Fi 连接'));
      await tester.pump();
      native.finish(2, 'connected');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Wi-Fi 已连接，请继续扫描空间码'), findsOneWidget);
      scanner.scan(_wifiCode);
      await tester.pump();
      expect(native.requests, hasLength(3));
      // 新输入框使用 Forui，中文输入、键盘提交和选择菜单仍应可用。
      await tester.ensureVisible(find.byType(EditableText));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(EditableText));
      await tester.enterText(find.byType(EditableText), '不是空间地址');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.longPress(find.byType(EditableText));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(native.released, contains(native.requests.last));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retained hotspot join verifies Host after a delayed switch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final native = _FakeNative();
    final scanner = _FakeScanner();
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = previous;
      await native.events.close();
      await scanner.captures.close();
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final invite = SpaceInvite.parse(
      'http://192.168.43.1:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
    );
    var metaAttempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: linkNestLocalizations,
        builder: (_, child) => LinkNestTheme(child: child!),
        home: JoinSpaceScreen(
          native: native,
          clientFactory: (value) => GuestApiClient(
            invite: value,
            client: MockClient((request) async {
              if (request.url.path == '/api/meta') {
                metaAttempts++;
                if (metaAttempts == 1) {
                  throw http.ClientException('Wi-Fi switching');
                }
              }
              return http.Response(
                jsonEncode({
                  'ok': true,
                  'data': request.url.path == '/api/meta'
                      ? {
                          'spaceId': 'trip',
                          'sessionId': 'session-1',
                          'spaceName': '旅行',
                          'spaceUpdatedAt': 1720000000000,
                          'visitorName': '访客',
                          'hostVersion': '1.2.0',
                          'protocolVersion': linkNestProtocolVersion,
                          'capabilities': linkNestCapabilities,
                        }
                      : [],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    scanner.scan(_wifiCode);
    await tester.pump();
    expect(native.requests, hasLength(1));
    native.finish(0, 'verificationPending');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('系统已受理连接请求，请扫描空间码确认'), findsOneWidget);
    expect(find.byType(SpaceGalleryScreen), findsNothing);
    scanner.scan(invite.url);
    await tester.pump();
    expect(find.byType(SpaceGalleryScreen), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(metaAttempts, greaterThanOrEqualTo(2));
    expect(find.byType(SpaceGalleryScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS system camera flow never requests in-app Wi-Fi join', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final native = _FakeNative();
    final scanner = _FakeScanner();
    final previous = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = scanner;
    addTearDown(() async {
      MobileScannerPlatform.instance = previous;
      await native.events.close();
      await scanner.captures.close();
    });
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final invite = SpaceInvite.parse(
      'http://192.168.43.1:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: linkNestLightTheme,
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: linkNestLocalizations,
        builder: (_, child) => LinkNestTheme(child: child!),
        home: JoinSpaceScreen(
          native: native,
          clientFactory: (value) => GuestApiClient(
            invite: value,
            client: MockClient(
              (request) async => http.Response(
                jsonEncode({
                  'ok': true,
                  'data': request.url.path == '/api/meta'
                      ? {
                          'spaceId': 'trip',
                          'sessionId': 'session-1',
                          'spaceName': '旅行',
                          'spaceUpdatedAt': 1720000000000,
                          'visitorName': '访客',
                          'hostVersion': '1.2.0',
                          'protocolVersion': linkNestProtocolVersion,
                          'capabilities': linkNestCapabilities,
                        }
                      : [],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('iPhone 系统相机扫描 Wi-Fi 码'), findsOneWidget);
    await tester.ensureVisible(find.text('系统相机连接指引'));
    await tester.tap(find.text('系统相机连接指引'));
    await tester.pumpAndSettle();
    expect(find.text('用系统相机连接热点'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    scanner.scan(_wifiCode);
    await tester.pump();
    expect(native.requests, isEmpty);
    native.connected = true;
    scanner.scan(invite.url);
    await tester.pumpAndSettle();
    expect(native.requests, isEmpty);
    expect(find.byType(SpaceGalleryScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}

class _FakeNative extends LinkNestNative {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final requests = <int>[];
  final replies = <Completer<String>>[];
  final released = <int>[];
  bool connected = false;
  @override
  Stream<void> get guestBackgroundTimeExpired => const Stream.empty();
  @override
  Future<void> stopGuestTransferService() async {}

  @override
  Stream<Map<String, dynamic>> get guestWifiChanges => events.stream;

  @override
  Future<String> joinGuestWifi({
    required int requestId,
    required String ssid,
    required String password,
    required String security,
    required bool hidden,
  }) {
    requests.add(requestId);
    final reply = Completer<String>();
    replies.add(reply);
    return reply.future;
  }

  void finish(int index, String status) {
    connected = status == 'connected' || status == 'verificationPending';
    replies[index].complete(status);
  }

  @override
  Future<void> releaseGuestWifi(int requestId) async {
    released.add(requestId);
  }

  @override
  Future<List<Map<String, dynamic>>> getLocalAddresses({
    bool diagnostic = false,
  }) async => connected
      ? [
          {'interface': 'wlan0', 'address': '192.168.43.2'},
        ]
      : [];
}

class _FakeScanner extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  int starts = 0;
  void scan(String value) =>
      captures.add(BarcodeCapture(barcodes: [Barcode(rawValue: value)]));
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}
