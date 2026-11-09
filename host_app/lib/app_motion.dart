import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

/// 所有时长集中调整；不通过延迟业务操作制造动画节奏。
abstract final class LinkNestMotion {
  static const enter = Duration(milliseconds: 300);
  static const exit = Duration(milliseconds: 220);
  static const content = Duration(milliseconds: 200);
  static const press = Duration(milliseconds: 100);
  static const release = Duration(milliseconds: 120);
  static const curve = Curves.easeOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      context.accessibility.motion != FAccessibilityMotion.all;

  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;
}

// 锁属于发起操作的页面，弹窗里的确认操作仍然可以正常执行。
final _navigationLocks = Expando<bool>('LinkNest navigation');

Future<T?> pushLinkNestRoute<T>(
  BuildContext context,
  TransitionRoute<T> route,
) async {
  final owner = ModalRoute.of(context);
  if (owner != null && (_navigationLocks[owner] == true || !owner.isCurrent)) {
    debugPrint('[LinkNest] 已忽略重复的界面打开操作');
    route.dispose();
    return null;
  }
  if (owner != null) _navigationLocks[owner] = true;
  final kind = route is PopupRoute ? '弹窗' : '页面';
  debugPrint('[LinkNest] 开始打开$kind');
  try {
    final result = await Navigator.of(context).push<T>(route);
    // popped 会在退出动画开始时完成；completed 才表示遮罩和旧页面已经离开。
    await route.completed;
    debugPrint('[LinkNest] $kind关闭过渡完成');
    return result;
  } finally {
    if (owner != null) _navigationLocks[owner] = false;
  }
}

Future<T?> pushLinkNestPage<T>(BuildContext context, WidgetBuilder builder) =>
    pushLinkNestRoute(context, MaterialPageRoute<T>(builder: builder));

Future<T?> showLinkNestDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final foruiTheme = FTheme.capture(from: context, to: navigator.context);
  return pushLinkNestRoute(
    context,
    _LinkNestDialogRoute<T>(
      exitDuration: LinkNestMotion.duration(context, LinkNestMotion.exit),
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black54,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: LinkNestMotion.duration(
        context,
        LinkNestMotion.enter,
      ),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: themes.wrap(foruiTheme.wrap(Builder(builder: builder))),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          LinkNestDialogTransition(animation: animation, child: child),
    ),
  );
}

class _LinkNestDialogRoute<T> extends RawDialogRoute<T> {
  _LinkNestDialogRoute({
    required this.exitDuration,
    required super.pageBuilder,
    required super.transitionBuilder,
    required super.transitionDuration,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.barrierLabel,
  });
  final Duration exitDuration;
  @override
  Duration get reverseTransitionDuration => exitDuration;
}

void popLinkNest<T>(BuildContext context, [T? result]) {
  final route = ModalRoute.of(context);
  if (route?.isCurrent != true ||
      route?.animation?.status == AnimationStatus.reverse) {
    return;
  }
  Navigator.of(context).pop<T>(result);
}

Future<bool> maybePopLinkNest(BuildContext context) async {
  final route = ModalRoute.of(context);
  if (route?.isCurrent != true ||
      route?.animation?.status == AnimationStatus.reverse) {
    return false;
  }
  return Navigator.of(context).maybePop();
}

/// 同一套进退曲线；动画只变换绘制，不逐帧重建弹窗内容。
class LinkNestDialogTransition extends StatelessWidget {
  const LinkNestDialogTransition({
    super.key,
    required this.animation,
    required this.child,
    this.fade = true,
  });
  final bool fade;
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (LinkNestMotion.reduced(context)) return child;
    final curved = animation.drive(CurveTween(curve: LinkNestMotion.curve));
    return FadeTransition(
      opacity: fade ? curved : kAlwaysCompleteAnimation,
      child: ScaleTransition(
        scale: curved.drive(Tween(begin: .96, end: 1.0)),
        child: child,
      ),
    );
  }
}

/// 用于状态内容的替换，退出内容不可点击，也不会重复出现在无障碍树中。
class LinkNestContentTransition extends StatelessWidget {
  const LinkNestContentTransition({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: LinkNestMotion.duration(context, LinkNestMotion.content),
    switchInCurve: LinkNestMotion.curve,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.center,
      children: [
        for (final old in previous)
          ExcludeSemantics(child: IgnorePointer(child: old)),
        ?current,
      ],
    ),
    child: child,
  );
}

/// 保留每页 Element/滚动状态，交叉淡入淡出；不重复挂载画廊或设置。
class LinkNestTabStack extends StatefulWidget {
  const LinkNestTabStack({
    super.key,
    required this.index,
    required this.children,
  });
  final int index;
  final List<Widget> children;

  @override
  State<LinkNestTabStack> createState() => _LinkNestTabStackState();
}

class _LinkNestTabStackState extends State<LinkNestTabStack> {
  late final Set<int> _visible = {widget.index};

  @override
  void didUpdateWidget(LinkNestTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visible.add(widget.index);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (var i = 0; i < widget.children.length; i++)
        Offstage(
          offstage: !_visible.contains(i),
          child: ExcludeSemantics(
            excluding: i != widget.index,
            child: IgnorePointer(
              ignoring: i != widget.index,
              child: AnimatedOpacity(
                // 连续切换从当前透明度继续，不能从零重新播放造成跳闪。
                opacity: i == widget.index ? 1 : 0,
                duration: LinkNestMotion.duration(
                  context,
                  LinkNestMotion.content,
                ),
                curve: LinkNestMotion.curve,
                onEnd: () {
                  if (mounted && i != widget.index) {
                    setState(() => _visible.remove(i));
                  }
                },
                child: TickerMode(
                  enabled: i == widget.index,
                  child: widget.children[i],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
