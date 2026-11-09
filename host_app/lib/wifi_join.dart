import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'native.dart';

// 临时使用 iOS 系统相机入网。恢复付费签名后，将此开关改为 true，
// 并在 Runner.entitlements 恢复 Hotspot Configuration 能力。
const bool iosHotspotConfigurationEnabled = false;

/// 凭证只在本次加入流程内存中使用；不要记录二维码原文。
class WifiCredentials {
  const WifiCredentials({
    required this.ssid,
    required this.password,
    required this.security,
    this.hidden = false,
  });

  final String ssid;
  final String password;
  final String security;
  final bool hidden;

  factory WifiCredentials.parse(String input) {
    if (!input.startsWith('WIFI:') || input.length > 4096) {
      throw const FormatException('不是可识别的 Wi-Fi 二维码');
    }
    final fields = <String, String>{};
    var part = StringBuffer();
    var escaped = false;
    void finishField() {
      final value = part.toString();
      part = StringBuffer();
      if (value.isEmpty) return;
      final separator = value.indexOf(':');
      if (separator <= 0) throw const FormatException('Wi-Fi 二维码格式不完整');
      final key = value.substring(0, separator);
      if (fields.containsKey(key)) {
        throw const FormatException('Wi-Fi 二维码包含重复字段');
      }
      fields[key] = value.substring(separator + 1);
    }

    for (final unit in input.substring(5).codeUnits) {
      if (escaped) {
        part.writeCharCode(unit);
        escaped = false;
      } else if (unit == 92) {
        escaped = true;
      } else if (unit == 59) {
        finishField();
      } else {
        part.writeCharCode(unit);
      }
    }
    if (escaped) throw const FormatException('Wi-Fi 二维码转义不完整');
    finishField();
    final ssid = fields['S'] ?? '';
    if (ssid.isEmpty ||
        utf8.encode(ssid).length > 32 ||
        ssid.contains('\u0000')) {
      throw const FormatException('热点名称为空或超过系统长度限制');
    }
    final type = (fields['T'] ?? 'nopass').toUpperCase();
    if (!['WPA', 'WPA2', 'NOPASS'].contains(type)) {
      throw const FormatException('此热点认证方式暂不支持，请手动连接');
    }
    final password = fields['P'] ?? '';
    if (type != 'NOPASS' &&
        (password.length < 8 ||
            password.length > 63 ||
            password.codeUnits.any((unit) => unit < 32 || unit > 126))) {
      throw const FormatException('此热点密码格式暂不支持，请手动连接');
    }
    if (fields['H'] != null &&
        !['true', 'false'].contains(fields['H']!.toLowerCase())) {
      throw const FormatException('Wi-Fi 二维码的隐藏网络标记无效');
    }
    return WifiCredentials(
      ssid: ssid,
      password: type == 'NOPASS' ? '' : password,
      security: type == 'NOPASS' ? 'open' : 'wpa2',
      hidden: fields['H']?.toLowerCase() == 'true',
    );
  }

  @override
  String toString() => 'WifiCredentials(凭证已隐藏)';
}

enum WifiJoinState {
  idle,
  connecting,
  verificationPending,
  connected,
  failed,
  disconnected,
}

/// 加入页持有此对象，推入画廊时继续持有；退出 Guest 流程才释放连接。
class GuestWifiController extends ChangeNotifier {
  GuestWifiController(
    this.native, {
    this.timeout = const Duration(seconds: 50),
  }) {
    _subscription = native.guestWifiChanges.listen((event) {
      if (_disposed ||
          event['requestId'] != _requestId ||
          event['state'] != 'lost') {
        return;
      }
      _requestId = null;
      state = WifiJoinState.disconnected;
      message = '热点连接已断开，请重试或连接发起者当前的热点';
      debugPrint('[LinkNest] 访客收到 Wi-Fi 断开通知');
      notifyListeners();
    });
  }

  final LinkNestNative native;
  final Duration timeout;
  static int _nextRequestId = 0;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  int? _requestId;
  bool _disposed = false;
  WifiCredentials? credentials;
  WifiJoinState state = WifiJoinState.idle;
  String? message;
  bool get connecting => state == WifiJoinState.connecting;

  Future<void> connect(WifiCredentials value) async {
    if (_disposed || connecting) return;
    final previous = _requestId;
    final id = ++_nextRequestId;
    _requestId = id;
    credentials = value;
    state = WifiJoinState.connecting;
    message = '请确认系统连接请求，正在连接 Wi-Fi…';
    notifyListeners();
    if (previous != null) await _releaseNative(previous);
    if (_disposed || _requestId != id) return;
    debugPrint('[LinkNest] 访客开始扫码连接 Wi-Fi requestId=$id');
    var status = 'failed';
    try {
      status = await native
          .joinGuestWifi(
            requestId: id,
            ssid: value.ssid,
            password: value.password,
            security: value.security,
            hidden: value.hidden,
          )
          .timeout(timeout);
    } on TimeoutException {
      status = 'timeout';
    } catch (error) {
      debugPrint('[LinkNest] 访客连接 Wi-Fi 异常 reason=${error.runtimeType}');
    }
    if (_disposed || _requestId != id) return;
    debugPrint('[LinkNest] 访客连接 Wi-Fi 结果 requestId=$id status=$status');
    if (status == 'connected' || status == 'verificationPending') {
      state = status == 'connected'
          ? WifiJoinState.connected
          : WifiJoinState.verificationPending;
      message = status == 'connected'
          ? 'Wi-Fi 已连接，请继续扫描空间码'
          : '系统已受理连接请求，请扫描空间码确认';
    } else {
      _requestId = null;
      state = status == 'cancelled' ? WifiJoinState.idle : WifiJoinState.failed;
      message = switch (status) {
        'cancelled' => '已取消连接，可以重新扫码',
        'permissionDenied' => '连接 Wi-Fi 需要系统授权，请允许后重试，或手动连接',
        'wifiOff' => '请先打开系统 Wi-Fi 开关，再重试连接',
        'locationOff' => '此 Android 版本需要开启系统定位开关才能连接 Wi-Fi',
        'timeout' => '连接 Wi-Fi 超时，请确认热点已开启后重试',
        'busy' => '上一次系统授权还未结束，请处理系统弹窗后重试',
        'unsupported' => '此设备暂不支持 App 内连接，请手动连接 Wi-Fi',
        'unsupportedNetwork' => '当前网络不受支持，请检查 Wi-Fi 后重试',
        'unavailable' => '未能连接热点，可能已取消授权、密码不匹配或热点不可用',
        _ => '连接 Wi-Fi 失败，请重试或手动连接',
      };
      await _releaseNative(id);
      if (_disposed || _requestId != null) return;
    }
    notifyListeners();
  }

  void confirmHostConnection() {
    if (_disposed || state != WifiJoinState.verificationPending) return;
    state = WifiJoinState.connected;
    message = '已连接发起者空间';
    notifyListeners();
  }

  Future<void> cancel() => release(clearCredentials: false);

  Future<void> release({bool clearCredentials = true}) async {
    final id = _requestId;
    _requestId = null;
    state = WifiJoinState.idle;
    message = clearCredentials ? null : '已取消连接，可以重试或重新扫码';
    if (clearCredentials) credentials = null;
    if (!_disposed) notifyListeners();
    if (id != null) await _releaseNative(id);
  }

  Future<void> _releaseNative(int id) async {
    try {
      await native.releaseGuestWifi(id).timeout(const Duration(seconds: 3));
    } catch (error) {
      debugPrint('[LinkNest] 释放访客 Wi-Fi 请求失败 reason=${error.runtimeType}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(release());
    super.dispose();
  }
}
