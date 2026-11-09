import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/history_screen.dart';
import 'package:linknest/main.dart';
import 'package:linknest/qrcodes.dart';
import 'package:linknest/server.dart';
import 'package:linknest/settings.dart';
import 'package:linknest/settings_state.dart';
import 'package:linknest/space_state.dart';

Widget _app(Widget home, {double scale = 1, bool dark = false}) => MaterialApp(
  theme: dark ? linkNestDarkTheme : linkNestLightTheme,
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: linkNestLocalizations,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: LinkNestTheme(child: child!),
  ),
  home: home,
);

void _smallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'About reads installed version and scrolls through usage on small screens',
    (tester) async {
      _smallScreen(tester);
      var version = '1.2.9';
      const channel = MethodChannel('linknest/native');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getAppVersion' ? version : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showLinkNestAbout(context),
                child: const Text('打开关于'),
              ),
            ),
          ),
          scale: 1.5,
        ),
      );
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();
      expect(find.text('版本 1.2.9'), findsOneWidget);
      expect(find.text('发起一次相聚'), findsOneWidget);
      expect(find.text('加入与保存'), findsOneWidget);
      await tester.ensureVisible(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('知道了').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      version = 'unknown';
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();
      expect(find.text('版本信息暂不可用'), findsOneWidget);
      expect(find.text('版本 1.0.0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creation starts empty and rejects an unnamed space without starting hotspot',
    (tester) async {
      _smallScreen(tester);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('linknest/native'),
        (call) async {
          calls.add(call.method);
          return call.method == 'getLocalIp' ? '192.168.1.1' : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('linknest/native'),
          null,
        ),
      );
      await tester.pumpWidget(_app(const RoleSelectionScreen(), scale: 1.5));
      await tester.pumpAndSettle();
      expect(find.byType(FHeader), findsNothing);
      expect(find.text('LinkNest'), findsNothing);
      expect(
        find.byKey(const ValueKey('home-history')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('创建空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建空间'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(find.text('例如：杭州三日游'), findsOneWidget);
      await tester.ensureVisible(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('请填写本次相聚名称'), findsOneWidget);
      expect(calls, isNot(contains('startHotspot')));
      await tester.enterText(find.byType(EditableText), '尚未创建的相聚');
      await tester.ensureVisible(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('创建空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建空间'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      await tester.ensureVisible(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'settings theme and rename keep existing state and save callback',
    (tester) async {
      _smallScreen(tester);
      final originalName = spaceName.value;
      addTearDown(() {
        spaceName.value = originalName;
        themeModeNotifier.value = ThemeMode.system;
      });
      spaceName.value = '这是一段很长的旅行空间名称用于验证小屏显示';
      final saved = <String>[];
      await tester.pumpWidget(
        _app(
          SettingsPage(
            url: 'http://192.168.1.1:8080',
            ssid: '',
            wifiPassword: '',
            running: true,
            onSpaceNameChanged: (value) async {
              saved.add(value);
              spaceName.value = value;
            },
          ),
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FTileGroup), findsNothing);
      expect(find.text('空间与连接'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate((widget) => widget is FSelect<ThemeMode>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(themeModeNotifier.value, ThemeMode.dark);
      await tester.ensureVisible(find.text('空间名称'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('空间名称'));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(FDialog),
        matching: find.byType(EditableText),
      );
      await tester.enterText(input, '新的旅行');
      // 模拟软键盘占用高度，弹窗操作必须仍可滚动到。
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('空间名称'));
      await tester.pumpAndSettle();
      await tester.enterText(input, '新的旅行');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(saved, ['新的旅行']);
      expect(find.text('新的旅行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dark QR dialog changes address and follows refreshed addresses',
    (tester) async {
      _smallScreen(tester);
      const primary = 'http://192.168.1.1:8080/?key=test';
      const backup = 'http://192.168.2.1:8080/?key=test';
      await tester.pumpWidget(
        _app(
          const SettingsPage(
            url: primary,
            alternativeUrls: [backup],
            ssid: '',
            wifiPassword: '',
            running: true,
          ),
          dark: true,
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('空间地址'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<QrImageView>(find.byType(QrImageView)).backgroundColor,
        Colors.white,
      );
      await tester.ensureVisible(
        find.byWidgetPredicate((widget) => widget is FSelect<String>),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((widget) => widget is FSelect<String>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('备用地址 1'));
      await tester.pumpAndSettle();
      expect(find.text(backup), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SpaceQrSection),
          matching: find.byType(FTile),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.text(backup)).overflow,
        TextOverflow.ellipsis,
      );
      expect(
        tester.getCenter(find.text('连接地址')).dy,
        closeTo(tester.getCenter(find.text('扫码无法连接时切换备用地址')).dy, 1),
      );
      await tester.ensureVisible(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(FDialog), findsNothing);
      await tester.pumpWidget(
        _app(const Scaffold(body: SpaceQrSection(url: primary))),
      );
      await tester.pumpWidget(
        _app(const Scaffold(body: SpaceQrSection(url: backup))),
      );
      await tester.pumpAndSettle();
      expect(find.text(backup), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Wi-Fi QR preserves Chinese and escaped runtime credentials', (
    tester,
  ) async {
    _smallScreen(tester);
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: SingleChildScrollView(
            child: WifiQrSection(ssid: '家人的热点;旅行', wifiPassword: '1234:5678'),
          ),
        ),
        dark: true,
        scale: 1.5,
      ),
    );
    await tester.pumpAndSettle();
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(find.text('家人的热点;旅行'), findsOneWidget);
    expect(find.text('1234:5678'), findsOneWidget);
    expect(find.byType(FTile), findsNothing);
    expect(
      tester.getCenter(find.text('本机热点名称')).dy,
      closeTo(tester.getCenter(find.text('家人的热点;旅行')).dy, 1),
    );
    expect(tester.widget<Text>(find.text('家人的热点;旅行')).maxLines, 1);
    expect(
      tester.widget<Text>(find.text('家人的热点;旅行')).overflow,
      TextOverflow.ellipsis,
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.longPress(find.text('家人的热点;旅行'));
    await tester.pumpAndSettle();
    expect(copied, '家人的热点;旅行');
    expect(qr.backgroundColor, Colors.white);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Wi-Fi fallback QR uses the current in-memory credentials', (
    tester,
  ) async {
    _smallScreen(tester);
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: SingleChildScrollView(
            child: QrCodesSection(
              url: 'http://192.168.1.2:8080/#token=abcdefghijklmnopqrstuvwxyz123456',
              ssid: 'Current Wi-Fi',
              wifiPassword: 'current-password',
              networkLabel: 'Wi-Fi 名称',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      wifiQrPayload('Current Wi-Fi', 'current-password'),
      'WIFI:T:WPA;S:Current Wi-Fi;P:current-password;;',
    );
    expect(find.byType(QrImageView), findsNWidgets(2));
    expect(find.text('Current Wi-Fi'), findsOneWidget);
    expect(find.text('current-password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history detail groups files and confirms deleting only the selected day',
    (tester) async {
      _smallScreen(tester);
      final server = _DetailServer();
      await tester.pumpWidget(
        _app(
          HistorySpaceDetailScreen(server: server, snapshot: server.snapshot),
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026年09月27日 · 1 个文件'), findsOneWidget);
      await tester.tap(find.text('12:00–12:59 · 1 个文件'));
      await tester.pumpAndSettle();
      final dividers = tester.widgetList<FDivider>(
        find.descendant(
          of: find.byKey(const ValueKey('2026年09月27日')),
          matching: find.byType(FDivider),
        ),
      );
      expect(dividers, hasLength(2));
      for (final divider in dividers) {
        expect(
          divider.style(
            FDividerStyle(color: Colors.red, padding: EdgeInsets.zero),
          ).color,
          Colors.transparent,
        );
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('2026年09月27日')),
          matching: find.text('旅行中的一张照片.jpg'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('删除当天文件').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(server.deleted, isEmpty);
      await tester.tap(find.text('删除当天文件').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(server.deleted, ['new']);
      expect(find.text('2026年09月27日 · 1 个文件'), findsNothing);
      expect(find.text('2026年09月26日 · 1 个文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('active history detail has no destructive controls', (
    tester,
  ) async {
    final server = _DetailServer(active: true);
    await tester.pumpWidget(
      _app(HistorySpaceDetailScreen(server: server, snapshot: server.snapshot)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('12:00–12:59 · 1 个文件'));
    await tester.pumpAndSettle();
    expect(find.text('该空间正在共享，可以查看，但不能删除。'), findsOneWidget);
    expect(find.text('删除当天文件'), findsNothing);
    expect(find.bySemanticsLabel('删除文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history hour stays expanded after deleting one file', (
    tester,
  ) async {
    final server = _DetailServer(sameHour: true);
    await tester.pumpWidget(
      _app(HistorySpaceDetailScreen(server: server, snapshot: server.snapshot)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('12:00–12:59 · 2 个文件'));
    await tester.pumpAndSettle();
    expect(find.text('new.jpg'), findsOneWidget);
    expect(find.text('old.jpg'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('删除文件').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(server.deleted, ['new']);
    expect(find.text('12:00–12:59 · 1 个文件'), findsOneWidget);
    expect(find.text('old.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DetailServer extends LinkNestServer {
  _DetailServer({this.active = false, this.sameHour = false});
  final bool active;
  final bool sameHour;
  final deleted = <String>[];
  HistorySpaceSnapshot get snapshot => HistorySpaceSnapshot(
    space: Space(
      id: 'history',
      name: '旅行记录',
      accessKey: 'test',
      createdAt: DateTime(2026, 9, 26),
      lastActivityAt: DateTime(2026, 9, 27),
      updatedAt: DateTime(2026, 9, 27),
    ),
    isActive: active,
    files: [
      for (final id in ['new', 'old'])
        if (!deleted.contains(id))
          FileRecord(
            id: id,
            name: sameHour ? '$id.jpg' : '旅行中的一张照片.jpg',
            size: 1024,
            mimeType: 'image/jpeg',
            kind: 'image',
            previewStatus: PreviewStatus.ready,
            uploader: 'host',
            sha256: 'test',
            uploadedAt: DateTime(
              2026,
              9,
              sameHour || id == 'new' ? 27 : 26,
              sameHour || id == 'new' ? 12 : 11,
            ),
          ),
    ],
  );
  @override
  Future<List<HistorySpaceSnapshot>> historySpaces() async => [snapshot];
  @override
  Future<Uint8List> historyThumbnail(String id) async => Uint8List(0);
  @override
  Future<void> deleteHistoryFiles(String spaceId, Set<String> ids) async =>
      deleted.addAll(ids);
}
