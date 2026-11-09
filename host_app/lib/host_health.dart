import 'native.dart';

abstract final class HostHealthPolicy {
  static String? iosIdleNotice({
    required DateTime now,
    required DateTime sharingStartedAt,
    required DateTime? lastVisitorSeenAt,
    required int onlineCount,
  }) {
    if (onlineCount > 0) return null;
    final reference = lastVisitorSeenAt ?? sharingStartedAt;
    final threshold = lastVisitorSeenAt == null
        ? const Duration(minutes: 2)
        : const Duration(minutes: 1);
    if (now.difference(reference) < threshold) return null;
    return '当前没有活跃访客。iOS 个人热点可能因空闲而变得不可发现，请让访客重新确认 WiFi；必要时回到系统设置检查个人热点。';
  }

  static String? powerNotice(DevicePowerState power) {
    final warnings = <String>[];
    if (!power.charging && power.level != null && power.level! <= 0.20) {
      warnings.add('当前电量约 ${(power.level! * 100).round()}%，建议接入电源后继续共享。');
    }
    if (power.lowPowerMode) {
      warnings.add('系统低电量模式已开启，后台活动可能更容易受到限制。');
    }
    return warnings.isEmpty ? null : warnings.join(' ');
  }
}
