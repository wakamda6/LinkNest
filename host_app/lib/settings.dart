import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'app_motion.dart';
import 'app_ui.dart';
import 'app_theme.dart';
import 'native.dart';
import 'qrcodes.dart';
import 'settings_state.dart';

/// 设置页：通用、空间设置及关于信息。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.url,
    this.alternativeUrls = const [],
    required this.ssid,
    required this.wifiPassword,
    required this.running,
    this.onSpaceNameChanged,
  });

  final String url;
  final List<String> alternativeUrls;
  final String ssid;
  final String wifiPassword;
  final bool running;
  final Future<void> Function(String name)? onSpaceNameChanged;

  @override
  Widget build(BuildContext context) {
    return LinkNestPage(
      title: '设置',
      showBack: !running,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsCard(title: '通用', tiles: [const _ThemeTile()]),
            const SizedBox(height: 16),
            SettingsCard(
              title: '空间与连接',
              tiles: [
                if (running) _SpaceNameTile(onChanged: onSpaceNameChanged),
                _ArrowTile(
                  title: '热点',
                  icon: FLucideIcons.wifi,
                  onTap: () => _openHotspot(context),
                ),
                _ArrowTile(
                  title: '空间地址',
                  icon: FLucideIcons.qrCode,
                  onTap: () => _openSpaceAddress(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SettingsCard(
              title: '其他',
              tiles: [
                _ArrowTile(
                  title: '关于 LinkNest',
                  icon: FLucideIcons.info,
                  onTap: () => showLinkNestAbout(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<void> _openHotspot(BuildContext context) async {
    debugPrint('[LinkNest] 已打开热点二维码设置 running=$running');
    await showLinkNestDialog<void>(
      context: context,
      builder: (dialogContext) => LinkNestDialog(
        title: '热点',
        actions: [
          LinkNestButton(
            label: '关闭',
            onPressed: () => popLinkNest(dialogContext),
          ),
        ],
        child: WifiQrSection(ssid: ssid, wifiPassword: wifiPassword),
      ),
    );
  }

  Future<void> _openSpaceAddress(BuildContext context) async {
    debugPrint('[LinkNest] 已打开空间地址设置 running=$running');
    await showLinkNestDialog<void>(
      context: context,
      builder: (dialogContext) => LinkNestDialog(
        title: '空间地址',
        actions: [
          LinkNestButton(
            label: '关闭',
            onPressed: () => popLinkNest(dialogContext),
          ),
        ],
        child: running
            ? SpaceQrSection(url: url, alternativeUrls: alternativeUrls)
            : const _NotRunningHint(),
      ),
    );
  }
}

Future<void> showLinkNestAbout(BuildContext context) async {
  debugPrint('[LinkNest] 已打开关于 LinkNest');
  await showLinkNestDialog<void>(
    context: context,
    builder: (dialogContext) => LinkNestDialog(
      title: '关于 LinkNest',
      actions: [
        LinkNestButton(
          label: '知道了',
          onPressed: () => popLinkNest(dialogContext),
        ),
      ],
      child: const _AboutLinkNestContent(),
    ),
  );
}

class _AboutLinkNestContent extends StatefulWidget {
  const _AboutLinkNestContent();

  @override
  State<_AboutLinkNestContent> createState() => _AboutLinkNestContentState();
}

class _AboutLinkNestContentState extends State<_AboutLinkNestContent> {
  late final Future<String?> _version = _readVersion();

  Future<String?> _readVersion() async {
    try {
      final version = (await LinkNestNative().getAppVersion()).trim();
      if (version.isEmpty || version == 'unknown') return null;
      debugPrint('[LinkNest] 关于页已读取安装版本 version=$version');
      return version;
    } catch (error) {
      debugPrint('[LinkNest] 关于页版本读取失败 reason=${error.runtimeType}');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: theme.typography.body.sm.copyWith(height: 1.55)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.asset(
              'assets/brand/linknest-icon.png',
              width: 64,
              height: 64,
              cacheWidth: 192,
              semanticLabel: 'LinkNest：相聚与分享',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '相聚即刻，美好即享',
          textAlign: TextAlign.center,
          style: theme.typography.body.md.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        FutureBuilder<String?>(
          future: _version,
          builder: (_, snapshot) => Text(
            snapshot.connectionState != ConnectionState.done
                ? '正在读取版本…'
                : snapshot.data == null
                ? '版本信息暂不可用'
                : '版本 ${snapshot.data}',
            textAlign: TextAlign.center,
            style: theme.typography.body.sm.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
        ),
        section(
          '一起分享美好',
          '基于手机热点的临时局域网共享系统。通过同一热点或 Wi-Fi，分享照片和视频，原文件传输、不压缩，也可查看历史空间。',
        ),
        section(
          '发起一次相聚',
          '首页点“创建空间”，填写名称后展示二维码。Android 会创建临时热点；iPhone 按提示手动开启个人热点。',
        ),
        section(
          '加入与保存',
          '点“加入空间”：Android 可在 App 内扫描 Wi-Fi 码；iPhone 请先用系统相机扫码加入热点，再返回 App 扫空间码。进入画廊后可添加照片、视频，或将喜欢的内容保存到相册。\n'
              '未安装 App 的朋友，可用系统相机连接热点，再用浏览器打开空间码。',
        ),
        section('下次继续相聚', '首页右上角进入历史空间。发起者可继续共享；参与者先连接发起者当前网络，再尝试进入原空间。'),
        section(
          '记得保存',
          '上传内容保存在发起者手机，关闭空间不会自动删除。想留在自己手机里的照片，请保存到相册。共享期间请让发起者 App 保持前台、热点保持开启。',
        ),
      ],
    );
  }
}

/// 分组标题置于柔和圆角面板内，不使用列表分割线。
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.title, required this.tiles});
  final String title;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LinkNestSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ...tiles,
      ],
    ),
  );
}

/// 左侧图标与名称，右侧控件；大字体下控件另起一行。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.control = false,
  });
  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool control;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              control &&
              (constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20);
          final heading = Row(
            children: [
              Icon(icon, size: 22, color: context.theme.colors.mutedForeground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.theme.typography.body.md),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: context.theme.typography.body.sm.copyWith(
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null && !stacked) ...[
                const SizedBox(width: 12),
                if (control)
                  SizedBox(width: 150, child: trailing)
                else
                  trailing!,
              ],
            ],
          );
          if (!stacked) return heading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [heading, const SizedBox(height: 12), trailing!],
          );
        },
      ),
    ),
  );
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context) => SettingsTile(
    title: '主题',
    icon: FLucideIcons.palette,
    control: true,
    trailing: ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => FSelect<ThemeMode>(
        items: const {
          '跟随系统': ThemeMode.system,
          '浅色': ThemeMode.light,
          '深色': ThemeMode.dark,
        },
        control: FSelectControl.lifted(
          value: mode,
          onChange: (value) {
            if (value != null) {
              debugPrint('[LinkNest] 已选择界面主题 mode=${value.name}');
              themeModeNotifier.value = value;
            }
          },
        ),
      ),
    ),
  );
}

/// 空间名称：点击直接编辑，展示给访客和空间页。
class _SpaceNameTile extends StatelessWidget {
  const _SpaceNameTile({this.onChanged});

  final Future<void> Function(String name)? onChanged;

  Future<void> _edit(BuildContext context) async {
    final result = await showLinkNestDialog<String>(
      context: context,
      builder: (_) =>
          LinkNestTextEditDialog(title: '空间名称', initial: spaceName.value),
    );
    if (result == null) return;
    final name = result.trim();
    if (name.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('空间名称不能为空')));
      }
      return;
    }
    try {
      final callback = onChanged;
      if (callback == null) {
        spaceName.value = name;
      } else {
        await callback(name);
      }
    } catch (error) {
      debugPrint('[LinkNest] 修改空间名称失败 reason=${error.runtimeType}');
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('空间名称保存失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: spaceName,
      builder: (context, name, _) => SettingsTile(
        title: '空间名称',
        icon: FLucideIcons.folder,
        subtitle: name.isEmpty ? '未设置' : name,
        onTap: () => _edit(context),
        trailing: const Icon(FLucideIcons.pencil, size: 18),
      ),
    );
  }
}

/// 箭头项：右侧 chevron，点击跳转。
class _ArrowTile extends StatelessWidget {
  const _ArrowTile({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      title: title,
      icon: icon,
      onTap: onTap,
      trailing: Icon(
        FLucideIcons.chevronRight,
        color: context.theme.colors.mutedForeground,
      ),
    );
  }
}

/// 未共享时的占位提示。
class _NotRunningHint extends StatelessWidget {
  const _NotRunningHint();

  @override
  Widget build(BuildContext context) {
    return Text(
      '尚未开始共享，开始共享后这里会显示内容。',
      style: context.theme.typography.body.sm.copyWith(
        color: context.theme.colors.mutedForeground,
      ),
    );
  }
}
