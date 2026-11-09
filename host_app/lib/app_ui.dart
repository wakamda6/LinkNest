import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';

/// 左右保留相同宽度，让中间名称真正居中；长名称完整缩放，不截断。
class LinkNestHeaderRow extends StatelessWidget {
  const LinkNestHeaderRow({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.sideWidth = 48,
  });

  final Widget title;
  final Widget? leading;
  final Widget? trailing;
  final double sideWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: sideWidth,
          height: 48,
          child: Align(alignment: Alignment.centerLeft, child: leading),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FittedBox(fit: BoxFit.scaleDown, child: title),
          ),
        ),
        SizedBox(
          width: sideWidth,
          height: 48,
          child: Align(alignment: Alignment.centerRight, child: trailing),
        ),
      ],
    ),
  );
}

/// 保留 Material 路由、键盘避让和 SnackBar，逐页替换显示组件。
class LinkNestPage extends StatelessWidget {
  const LinkNestPage({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.root = false,
    this.showBack = true,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final bool root;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final heading = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        title,
        maxLines: 1,
        softWrap: false,
        style: context.theme.typography.body.lg.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Scaffold(
      backgroundColor: context.theme.colors.background,
      body: SafeArea(
        child: Column(
          children: [
            if (root)
              FHeader(title: heading, suffixes: actions)
            else
              FHeader.nested(
                title: heading,
                prefixes: [
                  if (showBack && Navigator.of(context).canPop())
                    FButton.icon(
                      variant: FButtonVariant.ghost,
                      semanticsLabel: '返回',
                      onPress: () => maybePopLinkNest(context),
                      child: const Icon(FLucideIcons.chevronLeft),
                    ),
                ],
                suffixes: actions,
              ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SizedBox(width: double.infinity, child: child),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹窗内容和操作一起滚动，兼容小屏、大字体及软键盘。
/// 沿用 showDialog 的路由和遮罩，避免给旧设备增加背景模糊开销。
class LinkNestDialog extends StatelessWidget {
  const LinkNestDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => FDialog(
    semanticsLabel: title,
    style: .delta(
      decoration: .value(
        BoxDecoration(
          color: context.theme.colors.background,
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    constraints: const BoxConstraints(maxWidth: 440),
    builder: (context, style) => SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: context.theme.typography.body.lg.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          child,
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final horizontal =
                  actions.length <= 2 &&
                  constraints.maxWidth >= 320 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 20;
              if (horizontal) {
                return Row(
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: actions[i]),
                    ],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    actions[i],
                  ],
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

class LinkNestTextEditDialog extends StatefulWidget {
  const LinkNestTextEditDialog({
    super.key,
    required this.title,
    required this.initial,
  });
  final String title;
  final String initial;

  @override
  State<LinkNestTextEditDialog> createState() => _LinkNestTextEditDialogState();
}

class _LinkNestTextEditDialogState extends State<LinkNestTextEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => popLinkNest(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) => LinkNestDialog(
    title: widget.title,
    actions: [
      LinkNestButton(label: '确定', onPressed: _submit),
      LinkNestButton(
        label: '取消',
        variant: FButtonVariant.secondary,
        onPressed: () => popLinkNest(context),
      ),
    ],
    child: FTextField(
      control: FTextFieldControl.managed(controller: _controller),
      label: Text(widget.title),
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmit: (_) => _submit(),
    ),
  );
}

class LinkNestPanel extends StatelessWidget {
  const LinkNestPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) =>
      LinkNestSurface(padding: padding, child: child);
}

/// 无描边的柔和分组，用留白区分内容，浅深色随主题切换。
class LinkNestSurface extends StatelessWidget {
  const LinkNestSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
    color: context.theme.colors.secondary.withValues(alpha: 0.5),
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

/// 触屏尺寸的按钮，长文案在可用宽度内换行，不裁掉操作名称。
class LinkNestButton extends StatelessWidget {
  const LinkNestButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.variant = FButtonVariant.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final FButtonVariant variant;

  @override
  Widget build(BuildContext context) => FButton(
    onPress: onPressed,
    variant: variant,
    size: FButtonSizeVariant.lg,
    prefix: busy
        ? const SizedBox.square(dimension: 18, child: FCircularProgress())
        : icon == null
        ? null
        : Icon(icon),
    child: Flexible(child: Text(label, textAlign: TextAlign.center)),
  );
}

class LinkNestNotice extends StatelessWidget {
  const LinkNestNotice({
    super.key,
    required this.message,
    this.error = false,
    this.actions = const [],
  });
  final String message;
  final bool error;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: error ? colors.error.withValues(alpha: 0.08) : colors.muted,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    error ? FLucideIcons.circleAlert : FLucideIcons.info,
                    size: 18,
                    color: error ? colors.error : colors.mutedForeground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: context.theme.typography.body.sm.copyWith(
                        color: error ? colors.error : colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具栏和提示条的小按钮，长文字可换行，保持完整文案。
class LinkNestAction extends StatelessWidget {
  const LinkNestAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.selected = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool selected;

  @override
  Widget build(BuildContext context) => FButton(
    variant: selected ? FButtonVariant.secondary : FButtonVariant.ghost,
    mainAxisSize: MainAxisSize.min,
    onPress: onPressed,
    prefix: icon == null ? null : Icon(icon),
    child: Flexible(child: Text(label, textAlign: TextAlign.center)),
  );
}
