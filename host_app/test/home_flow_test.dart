import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/app_ui.dart';
import 'package:linknest/guest_space_history.dart';
import 'package:linknest/history_screen.dart';
import 'package:linknest/main.dart';
import 'package:linknest/native.dart';
import 'package:linknest/server.dart';
import 'package:linknest/space_invite.dart';
import 'package:linknest/space_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home, {bool disableAnimations = false}) => MaterialApp(
  theme: linkNestLightTheme,
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: linkNestLocalizations,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: LinkNestTheme(child: child!),
  ),
  home: home,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'name keyboard waits for entry and does not open after cancellation',
    (tester) async {
      final native = _Native();
      await tester.pumpWidget(
        _app(RoleSelectionScreen(server: _Server(), native: native)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建空间'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isFalse,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateSpaceNameDialog), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(native.starts, 0);

      await tester.tap(find.text('创建空间'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(native.starts, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion opens name keyboard without waiting for animation',
    (tester) async {
      final native = _Native();
      await tester.pumpWidget(
        _app(
          RoleSelectionScreen(server: _Server(), native: native),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建空间'));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(native.starts, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home logo scrolls with content while history stays fixed and About opens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(RoleSelectionScreen(server: _Server(), native: _Native())),
      );
      final logo = find.byKey(const ValueKey('home-logo'));
      final history = find.byKey(const ValueKey('home-history'));
      final initialLogoTop = tester.getTopLeft(logo).dy;
      final initialHistoryTop = tester.getTopLeft(history).dy;
      expect(initialLogoTop - initialHistoryTop, closeTo(16, 1));
      expect(
        find.ancestor(of: logo, matching: find.byType(ListView)),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        greaterThan(0),
      );
      expect(logo.hitTestable(), findsNothing);
      expect(tester.getTopLeft(history).dy, initialHistoryTop);
      expect(history.hitTestable(), findsOneWidget);
      final about = find.byKey(const ValueKey('home-about'));
      await tester.scrollUntilVisible(about, 160);
      await tester.tap(about);
      await tester.pumpAndSettle();
      expect(find.textContaining('基于手机热点的临时局域网共享系统'), findsOneWidget);
      await tester.ensureVisible(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(LinkNestDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home confirms a fresh name once, opens QR, and closes back home',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = _Server();
      final native = _Native();
      await tester.pumpWidget(
        _app(RoleSelectionScreen(server: server, native: native)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FHeader), findsNothing);
      expect(find.text('相聚即刻，美好即享'), findsOneWidget);
      await tester.tap(find.text('创建空间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '  周末相聚  ');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(server.names, ['周末相聚']);
      expect(native.starts, 1);
      final bottomBar = find.byType(FBottomNavigationBar);
      final barDecoration =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: bottomBar,
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(barDecoration.border, isNull);

      expect(find.text('第一步：扫描 Wi-Fi 码连接热点'), findsOneWidget);
      final stepTitle = tester.widget<Text>(find.text('第一步：扫描 Wi-Fi 码连接热点'));
      expect(stepTitle.maxLines, 1);
      expect(stepTitle.style?.fontSize, 13);
      final secondTitle = tester.widget<Text>(
        find.text('第二步：在 LinkNest 中扫描空间码'),
      );
      expect(secondTitle.style?.fontSize, stepTitle.style?.fontSize);
      expect(secondTitle.maxLines, 1);
      expect(find.text('本次相聚名称'), findsNothing);
      expect(find.textContaining('本机 IP'), findsNothing);
      final qrHeader = find.byKey(const ValueKey('qr-header'));
      final qrExit = find.byKey(const ValueKey('host-exit'));
      final qrEnter = find.byKey(const ValueKey('qr-enter'));
      expect(find.byIcon(FLucideIcons.history).hitTestable(), findsNothing);
      expect(find.textContaining('确认系统提示并加入热点'), findsNothing);
      expect(find.textContaining('未安装 LinkNest 时'), findsNothing);
      expect(
        tester.getCenter(qrExit).dx,
        lessThan(tester.getCenter(find.text('周末相聚')).dx),
      );
      expect(
        tester.getCenter(qrEnter).dx,
        greaterThan(tester.getCenter(find.text('周末相聚')).dx),
      );
      expect(
        tester.getCenter(find.text('周末相聚')).dx,
        closeTo(tester.getCenter(qrHeader).dx, 1),
      );
      await tester.tap(qrEnter);
      await tester.pumpAndSettle();
      expect(find.text('发起者'), findsOneWidget);
      expect(find.byIcon(FLucideIcons.history).hitTestable(), findsNothing);
      expect(
        tester.getCenter(find.text('周末相聚')).dy,
        closeTo(tester.getCenter(find.text('发起者')).dy, 1),
      );
      expect(
        tester.getCenter(find.text('周末相聚')).dx,
        lessThan(tester.getCenter(find.text('发起者')).dx),
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('host-online'))).dy,
        greaterThan(tester.getCenter(find.text('发起者')).dy),
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('host-online'))).dy,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('gallery-options'))).dy,
          1,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('host-online')),
          matching: find.text('0'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('人在线'), findsNothing);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('host-online')),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('host-online')));
      await tester.pumpAndSettle();
      expect(find.text('在线成员'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byKey(const ValueKey('host-exit'))).dy,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('gallery-upload'))).dy,
          1,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gallery-header')),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('host-exit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(LinkNestDialog),
          matching: find.text('关闭空间'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-history')), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(server.stops, 1);
      expect(native.stops, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('creation waits in a modal over home with animated dots', (
    tester,
  ) async {
    final server = _Server();
    final pending = Completer<Map<String, dynamic>>();
    final native = _Native()..pendingHotspot = pending;
    await tester.pumpWidget(
      _app(RoleSelectionScreen(server: server, native: native)),
    );
    await tester.tap(find.text('创建空间'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '周末相聚');
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final dialog = find.byKey(const ValueKey('creating-space-dialog'));
    expect(dialog, findsOneWidget);
    expect(find.byKey(const ValueKey('home-logo')), findsOneWidget);
    String waitingText() => tester
        .widget<Text>(find.descendant(of: dialog, matching: find.byType(Text)))
        .textSpan!
        .toPlainText();
    final before = waitingText();
    await tester.pump(const Duration(milliseconds: 500));
    expect(waitingText(), isNot(before));
    await tester.tapAt(const Offset(4, 4));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(dialog, findsOneWidget);
    expect(native.starts, 1);
    expect(server.names, isEmpty);

    pending.complete({'ssid': 'Test', 'password': 'password123'});
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.byKey(const ValueKey('qr-header')), findsOneWidget);
    expect(server.names, ['周末相聚']);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(native.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed creation retries the same name and can return without duplicate cleanup',
    (tester) async {
      final server = _Server()..failOnce = true;
      final native = _Native();
      await tester.pumpWidget(
        _app(RoleSelectionScreen(server: server, native: native)),
      );
      await tester.tap(find.text('创建空间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '重试相聚');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('创建未完成'), findsOneWidget);
      expect(find.byType(LinkNestDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('home-logo')), findsOneWidget);
      expect(native.stops, 1);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(server.names, ['重试相聚', '重试相聚']);
      expect(find.text('第一步：扫描 Wi-Fi 码连接热点'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(native.stops, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unified history labels roles and resumes the original Host space',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = _Server();
      final history = await GuestSpaceHistory.open();
      await history.remember(
        spaceId: 'guest-trip',
        name: '同名相聚',
        invite: _invite,
        joinedAt: DateTime.utc(2026, 9, 28),
      );
      await tester.pumpWidget(
        _app(RoleSelectionScreen(server: server, native: _Native())),
      );
      await tester.tap(find.byKey(const ValueKey('home-history')));
      await tester.pumpAndSettle();
      expect(find.text('发起者'), findsOneWidget);
      expect(find.text('参与者'), findsOneWidget);
      expect(find.text('同名相聚'), findsNWidgets(2));
      final guest = find.byKey(const ValueKey('guest:guest-trip'));
      final host = find.byKey(const ValueKey('host:host-trip'));
      expect(tester.getTopLeft(guest).dy, lessThan(tester.getTopLeft(host).dy));
      expect(
        find.descendant(of: guest, matching: find.text('删除空间')),
        findsNothing,
      );
      await tester.tap(find.text('继续共享'));
      await tester.pumpAndSettle();
      expect(server.resumes, ['host-trip']);
      expect(server.names, [null]);
      expect(find.byType(CreateSpaceNameDialog), findsNothing);
      expect(find.text('第一步：扫描 Wi-Fi 码连接热点'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('participant deletion confirms and preserves other history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = _Server();
    final history = await GuestSpaceHistory.open();
    for (final id in ['guest-trip', 'other-trip']) {
      await history.remember(spaceId: id, name: '同名相聚', invite: _invite);
    }
    await tester.pumpWidget(
      _app(
        HistorySpacesScreen(
          server: server,
          allowResume: true,
          includeJoinedSpaces: true,
          guestCacheRemover: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final guest = find.byKey(const ValueKey('guest:guest-trip'));
    final remove = find.descendant(of: guest, matching: find.text('删除记录'));
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(
      find.text('将删除本机的这条参与记录及对应媒体缓存，不删除发起者的空间、文件或已保存到系统相册的内容。'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(guest, findsOneWidget);
    expect((await GuestSpaceHistory.open()).spaces, hasLength(2));

    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(guest, findsNothing);
    expect(find.byKey(const ValueKey('guest:other-trip')), findsOneWidget);
    expect(find.byKey(const ValueKey('host:host-trip')), findsOneWidget);
    expect(
      (await GuestSpaceHistory.open()).spaces.single.spaceId,
      'other-trip',
    );
    expect(server.deletedSpaces, isEmpty);
    expect(server.names, isEmpty);
    expect(server.resumes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'participant history selection returns original address and ID without starting Host',
    (tester) async {
      final server = _Server();
      final history = await GuestSpaceHistory.open();
      await history.remember(
        spaceId: 'guest-trip',
        name: '参与的相聚',
        invite: _invite,
        joinedAt: DateTime.utc(2026, 9, 28),
      );
      Object? selected;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('历史入口'),
                onPressed: () async {
                  selected = await Navigator.of(context).push<Object>(
                    MaterialPageRoute(
                      builder: (_) => HistorySpacesScreen(
                        server: server,
                        allowResume: true,
                        includeJoinedSpaces: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('历史入口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入空间'));
      await tester.pumpAndSettle();
      expect(selected, isA<RecentGuestSpace>());
      expect((selected as RecentGuestSpace).spaceId, 'guest-trip');
      expect((selected as RecentGuestSpace).inviteUrl, _invite.url);
      expect(server.names, isEmpty);
      expect(server.resumes, isEmpty);
    },
  );
}

final _invite = SpaceInvite.parse(
  'http://192.168.43.1:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
);

class _Native extends LinkNestNative {
  Completer<Map<String, dynamic>>? pendingHotspot;
  int starts = 0;
  int stops = 0;
  @override
  Future<List<Map<String, dynamic>>> getLocalAddresses({
    bool diagnostic = false,
  }) async => const [];
  @override
  Future<Map<String, dynamic>> startHotspot() async {
    starts++;
    return pendingHotspot?.future ??
        Future.value({'ssid': 'Test', 'password': 'password123'});
  }

  @override
  Future<void> stopHotspot() async {
    stops++;
  }

  @override
  Future<void> setKeepAwake(bool enabled) async {}
  @override
  Future<DevicePowerState> getPowerState() async =>
      const DevicePowerState(level: 1, charging: true, lowPowerMode: false);
}

class _Server extends LinkNestServer {
  final names = <String?>[];
  final resumes = <String?>[];
  final deletedSpaces = <String>[];
  int stops = 0;
  bool failOnce = false;
  @override
  String get inviteUrl => _invite.url;
  @override
  List<String> get inviteUrls => [_invite.url];
  @override
  Future<String> start({
    int port = 8080,
    String? newSpaceName,
    String? resumeSpaceId,
    String? selectedAddress,
    String? selectedInterface,
    bool bindSelectedAddress = false,
  }) async {
    names.add(newSpaceName);
    resumes.add(resumeSpaceId);
    if (failOnce) {
      failOnce = false;
      throw StateError('模拟启动失败');
    }
    return _invite.baseUri.toString();
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> resolveHistoryLocations() async {}
  @override
  Future<void> deleteHistorySpace(String spaceId) async {
    deletedSpaces.add(spaceId);
  }

  @override
  Future<List<HistorySpaceSnapshot>> historySpaces() async => [
    HistorySpaceSnapshot(
      space: Space(
        id: 'host-trip',
        name: '同名相聚',
        accessKey: 'test',
        createdAt: DateTime.utc(2026, 9, 27),
        lastActivityAt: DateTime.utc(2026, 9, 27),
        updatedAt: DateTime.utc(2026, 9, 27),
      ),
      files: const [],
      isActive: false,
    ),
  ];
}
