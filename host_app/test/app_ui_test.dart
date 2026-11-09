import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/history_screen.dart';
import 'package:linknest/main.dart';
import 'package:linknest/server.dart';
import 'package:linknest/space_state.dart';

Widget _app(Widget home, {double textScale = 1}) => MaterialApp(
  theme: linkNestLightTheme,
  supportedLocales: const [Locale('zh'), Locale('en')],
  locale: const Locale('zh'),
  localizationsDelegates: linkNestLocalizations,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: LinkNestTheme(child: child!),
  ),
  home: home,
);

void main() {
  testWidgets('theme follows system and explicit override with teal retained', (
    tester,
  ) async {
    addTearDown(() => themeModeNotifier.value = ThemeMode.system);
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    themeModeNotifier.value = ThemeMode.system;
    await tester.pumpWidget(const LinkNestApp());
    await tester.pumpAndSettle();
    var context = tester.element(find.byType(RoleSelectionScreen));
    expect(context.theme.colors.brightness, Brightness.light);
    expect(
      context.theme.colors.primary,
      ColorScheme.fromSeed(seedColor: Colors.teal).primary,
    );

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pumpAndSettle();
    context = tester.element(find.byType(RoleSelectionScreen));
    expect(context.theme.colors.brightness, Brightness.dark);
    expect(Theme.of(context).brightness, Brightness.dark);

    themeModeNotifier.value = ThemeMode.light;
    await tester.pumpAndSettle();
    context = tester.element(find.byType(RoleSelectionScreen));
    expect(context.theme.colors.brightness, Brightness.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home actions remain reachable on a narrow screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app(const RoleSelectionScreen(), textScale: 2));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('创建空间'), 160);
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('创建空间'),
                matching: find.byType(FButton),
              ),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.scrollUntilVisible(find.text('加入空间'), 160);
      expect(find.text('加入空间').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history preserves long titles, active protection and delete confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = _HistoryServer();
      await tester.pumpWidget(
        _app(
          HistorySpacesScreen(server: server, allowResume: true),
          textScale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('共享中'), findsOneWidget);
      expect(find.byType(FCard), findsNothing);
      expect(find.text(_longName), findsOneWidget);
      // 共享中的卡片不能出现继续或删除操作；仅未共享卡片有操作入口。
      expect(find.text('继续共享'), findsOneWidget);
      expect(find.text('删除空间'), findsOneWidget);
      await tester.ensureVisible(find.text('删除空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(server.deleted, isEmpty);
      await tester.tap(find.text('删除空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(server.deleted, ['past']);
      expect(find.text('删除空间'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resuming history returns the original space to its caller', (
    tester,
  ) async {
    final server = _HistoryServer();
    Space? selected;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await Navigator.of(context).push<Space>(
                  MaterialPageRoute(
                    builder: (_) =>
                        HistorySpacesScreen(server: server, allowResume: true),
                  ),
                );
              },
              child: const Text('历史入口'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('历史入口'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('继续共享'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续共享'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'past');
    expect(selected?.name, _longName);
    expect(tester.takeException(), isNull);
  });
}

const _longName = '和家人一起去海边度假的照片与视频记录';

class _HistoryServer extends LinkNestServer {
  final deleted = <String>[];

  @override
  Future<List<HistorySpaceSnapshot>> historySpaces() async => [
    for (final id in ['active', 'past'])
      if (!deleted.contains(id))
        HistorySpaceSnapshot(
          space: Space(
            id: id,
            name: id == 'active' ? '正在共享的旅行' : _longName,
            accessKey: 'test',
            createdAt: DateTime.utc(2026, 9, 27),
            lastActivityAt: DateTime.utc(2026, 9, 27),
            updatedAt: DateTime.utc(2026, 9, 27),
          ),
          files: const [],
          isActive: id == 'active',
        ),
  ];

  @override
  Future<void> resolveHistoryLocations() async {}

  @override
  Future<void> deleteHistorySpace(String id) async => deleted.add(id);
}
