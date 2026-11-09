import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/settings.dart';

Widget _app(Widget home) => MaterialApp(
  theme: linkNestLightTheme,
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: linkNestLocalizations,
  builder: (_, child) => LinkNestTheme(child: child!),
  home: home,
);

const _settings = SettingsPage(
  url: 'http://192.168.1.1:8080',
  ssid: '',
  wifiPassword: '',
  running: false,
);

void main() {
  testWidgets('settings open and close the bundled privacy policy', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_settings));
    await tester.pumpAndSettle();
    expect(find.text('隐私政策'), findsOneWidget);

    await tester.ensureVisible(find.text('隐私政策'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐私政策'));
    await tester.pumpAndSettle();

    expect(find.text('局域网共享'), findsOneWidget);
    expect(find.text('设备权限及用途'), findsOneWidget);
    expect(find.textContaining('本声明适用于 LinkNest Android'), findsOneWidget);
    expect(find.textContaining('LinkNest GitHub Issues'), findsOneWidget);

    await tester.ensureVisible(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('局域网共享'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
