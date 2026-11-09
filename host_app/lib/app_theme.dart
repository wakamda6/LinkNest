import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';

/// 全局主题模式由 persistence.dart 保存，继续使用原有青绿色配色。
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);

// Forui 使用独立的 Material/Cupertino 包，旧页面仍使用 Flutter 内置版本。
// 两组本地化类型不同，迁移期间同时提供，支持中文弹窗和文本选择。
const linkNestLocalizations = [
  ...GlobalMaterialLocalizations.delegates,
  ...FLocalizations.localizationsDelegates,
];

final linkNestLightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  useMaterial3: true,
);
final linkNestDarkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
);

// 只创建两份主题；页面轮询、扫码与列表刷新不重复生成组件样式。
final linkNestLightForuiTheme = _foruiTheme(linkNestLightTheme.colorScheme);
final linkNestDarkForuiTheme = _foruiTheme(linkNestDarkTheme.colorScheme);

FThemeData _foruiTheme(ColorScheme colors) {
  final base = colors.brightness == Brightness.dark
      ? FColors.neutralDark
      : FColors.neutralLight;
  final colorsForui = base.copyWith(
    primary: colors.primary,
    primaryForeground: colors.onPrimary,
    secondary: colors.secondaryContainer,
    secondaryForeground: colors.onSecondaryContainer,
    background: colors.surface,
    foreground: colors.onSurface,
    card: colors.surfaceContainerLow,
    muted: colors.surfaceContainerHighest,
    mutedForeground: colors.onSurfaceVariant,
    border: colors.outlineVariant,
    destructive: colors.error,
    destructiveForeground: colors.onError,
    error: colors.error,
    errorForeground: colors.onError,
  );
  final typography = FTypography.inherit(colors: colorsForui, touch: true);
  final tappable = FTappableStyle(
    motion: const FTappableMotion(
      bounceDownDuration: LinkNestMotion.press,
      bounceUpDuration: LinkNestMotion.release,
      bounceDownCurve: Curves.easeOutCubic,
      bounceUpCurve: Curves.easeOutCubic,
      bounceTween: FImmutableTween(begin: 1.0, end: .98),
      bounceFloor: 3,
    ),
  );
  return FThemeData(
    debugLabel: 'LinkNest ${colors.brightness.name}',
    touch: true,
    colors: colorsForui,
    typography: typography,
    style: FStyle.inherit(
      colors: colorsForui,
      typography: typography,
      touch: true,
    ).copyWith(tappableStyle: tappable),
    tappableStyle: tappable,
  );
}

/// 放在 MaterialApp.builder 内，使普通页面、弹窗和底部面板共享主题。
class LinkNestTheme extends StatefulWidget {
  const LinkNestTheme({super.key, required this.child});
  final Widget child;

  @override
  State<LinkNestTheme> createState() => _LinkNestThemeState();
}

class _LinkNestThemeState extends State<LinkNestTheme> {
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness != brightness) {
      _brightness = brightness;
      debugPrint('[LinkNest] 界面主题已更新 mode=${brightness.name}');
    }
  }

  @override
  Widget build(BuildContext context) => FTheme(
    data: Theme.of(context).brightness == Brightness.dark
        ? linkNestDarkForuiTheme
        : linkNestLightForuiTheme,
    child: FToaster(child: FTooltipGroup(child: widget.child)),
  );
}
