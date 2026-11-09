import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/app_motion.dart';
import 'package:linknest/app_theme.dart';
import 'package:linknest/app_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
  theme: linkNestLightTheme,
  localizationsDelegates: linkNestLocalizations,
  builder: (context, child) => LinkNestTheme(
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
  ),
  home: child,
);

void main() {
  testWidgets(
    'dialog rejects duplicate opens and finishes only after its exit',
    (tester) async {
      late BuildContext origin;
      late BuildContext dialogContext;
      var finished = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              origin = context;
              return const Scaffold(body: Text('原页面'));
            },
          ),
        ),
      );
      Widget dialog(BuildContext context) {
        dialogContext = context;
        return LinkNestDialog(
          title: '测试弹窗',
          actions: const [],
          child: const Text('内容'),
        );
      }

      final result = showLinkNestDialog<bool>(context: origin, builder: dialog);
      result.then((_) => finished = true);
      expect(
        await showLinkNestDialog<bool>(context: origin, builder: dialog),
        isNull,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final route = ModalRoute.of(dialogContext)!;
      expect(route.animation!.value, allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      popLinkNest(dialogContext, true);
      popLinkNest(dialogContext, true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(finished, isFalse);
      expect(find.text('测试弹窗'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(finished, isTrue);
      expect(find.text('原页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion skips the custom dialog transition', (
    tester,
  ) async {
    late BuildContext origin;
    late BuildContext dialogContext;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            origin = context;
            return const Scaffold();
          },
        ),
        reduced: true,
      ),
    );
    final pending = showLinkNestDialog<void>(
      context: origin,
      builder: (context) {
        dialogContext = context;
        return const LinkNestDialog(
          title: '简化动效',
          actions: [],
          child: Text('内容'),
        );
      },
    );
    await tester.pumpAndSettle();
    expect(ModalRoute.of(dialogContext)!.transitionDuration, Duration.zero);
    expect(find.byType(LinkNestDialog), findsOneWidget);
    popLinkNest(dialogContext);
    await tester.pumpAndSettle();
    await pending;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tab switching preserves input and disables outgoing interactions',
    (tester) async {
      final selected = ValueNotifier(0);
      addTearDown(selected.dispose);
      var outgoingTaps = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, index, _) => LinkNestTabStack(
                index: index,
                children: [
                  Column(
                    children: [
                      const TextField(),
                      TextButton(
                        onPressed: () => outgoingTaps++,
                        child: const Text('旧页操作'),
                      ),
                    ],
                  ),
                  const Center(child: Text('设置内容')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '保留的输入');
      selected.value = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('旧页操作').hitTestable(), findsNothing);
      expect(outgoingTaps, 0);
      selected.value = 0;
      await tester.pump();
      selected.value = 1;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('设置内容'), findsOneWidget);
      selected.value = 0;
      await tester.pumpAndSettle();
      expect(find.text('保留的输入'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
