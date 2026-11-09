import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:forui/forui.dart';

import 'app_ui.dart';

/// Wi-Fi 码组件：只读显示当前运行态传入的网络凭据。
/// 不含标题，由使用方（热点弹窗 / QrCodesSection）决定是否加标题。
class WifiQrSection extends StatelessWidget {
  const WifiQrSection({
    super.key,
    required this.ssid,
    required this.wifiPassword,
    this.networkLabel = '本机热点名称',
  });

  final String ssid;
  final String wifiPassword;
  final String networkLabel;

  @override
  Widget build(BuildContext context) {
    if (ssid.isEmpty || wifiPassword.isEmpty) {
      return const _Hint('未生成 Wi-Fi 连接码。请提醒访客先手动连接此 Wi-Fi 或热点，再扫描空间码。');
    }
    return _WifiDisplay(
      ssid: ssid,
      password: wifiPassword,
      networkLabel: networkLabel,
    );
  }
}

/// 热点信息只读展示：二维码 + 名称 + 密码。
class _WifiDisplay extends StatelessWidget {
  const _WifiDisplay({
    required this.ssid,
    required this.password,
    required this.networkLabel,
  });

  final String ssid;
  final String password;
  final String networkLabel;

  @override
  Widget build(BuildContext context) {
    final wifiQr = wifiQrPayload(ssid, password);
    return Column(
      children: [
        Center(child: _buildQr(wifiQr)),
        const SizedBox(height: 6),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              children: [
                _infoRow(context, networkLabel, ssid),
                const SizedBox(height: 2),
                _infoRow(context, '密码', password),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 标签与内容同排；只省略显示，二维码与复制使用完整凭证。
Widget _infoRow(BuildContext context, String label, String value) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: value.isEmpty ? null : () => _copyValue(context, label, value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 100),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: context.theme.typography.body.sm.copyWith(
                  fontSize: 11,
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value.isEmpty ? '未填写' : value,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.body.sm.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 空间码组件：显示访问地址（URL）的二维码 + URL 文本。
/// 不含标题，由使用方（空间地址弹窗 / QrCodesSection）决定是否加标题。
class SpaceQrSection extends StatefulWidget {
  const SpaceQrSection({
    super.key,
    required this.url,
    this.alternativeUrls = const [],
  });

  final String url;
  final List<String> alternativeUrls;

  @override
  State<SpaceQrSection> createState() => _SpaceQrSectionState();
}

class _SpaceQrSectionState extends State<SpaceQrSection> {
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.url;
  }

  List<String> get _urls => {
    widget.url,
    ...widget.alternativeUrls,
  }.where((value) => value.isNotEmpty).toList();

  @override
  void didUpdateWidget(covariant SpaceQrSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_urls.contains(_selected)) _selected = widget.url;
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
    return Column(
      children: [
        Center(child: _buildQr(_selected)),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: _selected.isEmpty
              ? null
              : () => _copyValue(context, '空间地址', _selected),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                _selected,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.body.sm.copyWith(fontSize: 12),
              ),
            ),
          ),
        ),
        if (urls.length > 1) ...[
          const SizedBox(height: 4),
          FSelect<String>(
            label: Row(
              children: [
                Text(
                  '连接地址',
                  style: context.theme.typography.body.sm.copyWith(
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '扫码无法连接时切换备用地址',
                      maxLines: 1,
                      softWrap: false,
                      style: context.theme.typography.body.sm.copyWith(
                        fontSize: 11,
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            items: {
              for (var i = 0; i < urls.length; i++)
                (i == 0 ? '首选地址' : '备用地址 $i'): urls[i],
            },
            control: FSelectControl.lifted(
              value: _selected,
              onChange: (value) {
                if (value != null) {
                  debugPrint(
                    '[LinkNest] 已切换空间码地址 index=${urls.indexOf(value)}',
                  );
                  setState(() => _selected = value);
                }
              },
            ),
          ),
        ],
      ],
    );
  }
}

Future<void> _copyValue(
  BuildContext context,
  String label,
  String value,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  debugPrint('[LinkNest] 已复制字段 field=$label');
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('已复制$label')));
}

/// 两码组合组件：WiFi 码 + 空间码（引导页复用）。
class QrCodesSection extends StatelessWidget {
  const QrCodesSection({
    super.key,
    required this.url,
    this.alternativeUrls = const [],
    required this.ssid,
    required this.wifiPassword,
    this.showWifiStep = true,
    this.networkLabel = '本机热点名称',
  });

  final String url;
  final List<String> alternativeUrls;
  final String ssid;
  final String wifiPassword;
  final bool showWifiStep;
  final String networkLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showWifiStep)
          LinkNestPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SubTitle('第一步：扫描 Wi-Fi 码连接热点', compact: true),
                WifiQrSection(
                  ssid: ssid,
                  wifiPassword: wifiPassword,
                  networkLabel: networkLabel,
                ),
              ],
            ),
          ),
        if (showWifiStep) const SizedBox(height: 10),
        LinkNestPanel(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SubTitle(
                showWifiStep ? '第二步：在 LinkNest 中扫描空间码' : '扫描空间码加入',
                compact: true,
              ),
              SpaceQrSection(url: url, alternativeUrls: alternativeUrls),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _buildQr(String data) {
  // QrImageView 内部用 LayoutBuilder 自适配尺寸，放在 AlertDialog（IntrinsicWidth）
  // 里会被问内在尺寸而崩溃；外层套固定 SizedBox.square，让内在尺寸计算在此短路。
  return SizedBox.square(
    dimension: 200,
    child: QrImageView(
      data: data,
      version: QrVersions.auto,
      size: 200,
      backgroundColor: Colors.white,
      padding: const EdgeInsets.all(12),
    ),
  );
}

String wifiQrPayload(String ssid, String password) {
  return 'WIFI:T:WPA;S:${_escapeWifi(ssid)};P:${_escapeWifi(password)};;';
}

String _escapeWifi(String s) {
  return s
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(':', '\\:')
      .replaceAll(',', '\\,')
      .replaceAll('"', '\\"');
}

class _SubTitle extends StatelessWidget {
  const _SubTitle(this.text, {this.compact = false});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      text,
      maxLines: compact ? 1 : null,
      softWrap: !compact,
      style: context.theme.typography.body.md.copyWith(
        fontSize: compact ? 13 : null,
        fontWeight: FontWeight.w600,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: compact
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: title,
            )
          : title,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: context.theme.typography.body.sm.copyWith(
        color: context.theme.colors.mutedForeground,
      ),
    );
  }
}
