import 'package:linknest/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/main.dart';

void main() {
  Widget app({required VoidCallback onPressed, required VoidCallback onForce}) {
    return MaterialApp(
      theme: linkNestLightTheme,
      localizationsDelegates: linkNestLocalizations,
      supportedLocales: const [Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
      builder: (_, child) => LinkNestTheme(child: child!),
      home: Scaffold(
        appBar: AppBar(
          actions: [
            CloseSpaceButton(
              enabled: true,
              onPressed: onPressed,
              onForceClose: onForce,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('quick tap runs the normal close action', (tester) async {
    var normal = 0;
    var forced = 0;
    await tester.pumpWidget(
      app(onPressed: () => normal++, onForce: () => forced++),
    );

    await tester.tap(find.byKey(const ValueKey('host-exit')));
    await tester.pump();

    expect(normal, 1);
    expect(forced, 0);
  });

  testWidgets('releasing a long hold before five seconds cancels it', (
    tester,
  ) async {
    var normal = 0;
    var forced = 0;
    await tester.pumpWidget(
      app(onPressed: () => normal++, onForce: () => forced++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('host-exit'))),
    );
    await tester.pump(const Duration(seconds: 4));
    await gesture.up();
    await tester.pump();

    expect(normal, 0);
    expect(forced, 0);
  });

  testWidgets('holding for five seconds runs only the force action', (
    tester,
  ) async {
    var normal = 0;
    var forced = 0;
    await tester.pumpWidget(
      app(onPressed: () => normal++, onForce: () => forced++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('host-exit'))),
    );
    await tester.pump(const Duration(seconds: 5));

    expect(normal, 0);
    expect(forced, 1);

    await gesture.up();
    await tester.pump();
    expect(normal, 0);
    expect(forced, 1);
  });
}
