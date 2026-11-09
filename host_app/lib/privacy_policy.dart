import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_ui.dart';

final _privacyPolicyText = rootBundle.loadString('assets/legal/privacy.md');

Future<void> showLinkNestPrivacyPolicy(BuildContext context) async {
  debugPrint('[LinkNest] 已打开隐私政策');
  await showLinkNestDialog<void>(
    context: context,
    builder: (dialogContext) => LinkNestDialog(
      title: '隐私政策',
      actions: [
        LinkNestButton(
          label: '关闭',
          onPressed: () => popLinkNest(dialogContext),
        ),
      ],
      child: const _PrivacyPolicyBody(),
    ),
  );
}

class _PrivacyPolicyBody extends StatelessWidget {
  const _PrivacyPolicyBody();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _privacyPolicyText,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            '隐私政策加载失败，请关闭后重试。',
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.error,
            ),
          );
        }
        final source = snapshot.data;
        if (source == null) {
          return Text('正在加载…', style: context.theme.typography.body.sm);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _privacyPolicyChildren(context, source),
        );
      },
    );
  }
}

List<Widget> _privacyPolicyChildren(BuildContext context, String source) {
  final theme = context.theme;
  final children = <Widget>[];
  for (final rawLine in source.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line == '# LinkNest 隐私声明') continue;
    if (line.startsWith('## ')) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 8),
          child: Text(
            line.substring(3),
            style: theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
      continue;
    }
    if (line.startsWith('更新日期：')) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText(
            line,
            style: theme.typography.body.sm.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
        ),
      );
      continue;
    }
    if (line.startsWith('- ')) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('•', style: theme.typography.body.sm),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  _plainText(line.substring(2)),
                  style: theme.typography.body.sm.copyWith(height: 1.65),
                ),
              ),
            ],
          ),
        ),
      );
      continue;
    }
    children.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SelectableText(
          _plainText(line),
          style: theme.typography.body.sm.copyWith(height: 1.7),
        ),
      ),
    );
  }
  return children;
}

String _plainText(String value) => value.replaceAllMapped(
  RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
  (match) => '${match[1]}（${match[2]}）',
);
