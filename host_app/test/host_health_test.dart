import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/host_health.dart';
import 'package:linknest/native.dart';

void main() {
  test(
    'iOS idle notice uses separate first-join and disconnect thresholds',
    () {
      final started = DateTime(2026, 9, 19, 12);

      expect(
        HostHealthPolicy.iosIdleNotice(
          now: started.add(const Duration(seconds: 119)),
          sharingStartedAt: started,
          lastVisitorSeenAt: null,
          onlineCount: 0,
        ),
        isNull,
      );
      expect(
        HostHealthPolicy.iosIdleNotice(
          now: started.add(const Duration(minutes: 2)),
          sharingStartedAt: started,
          lastVisitorSeenAt: null,
          onlineCount: 0,
        ),
        isNotNull,
      );

      final lastSeen = started.add(const Duration(minutes: 3));
      expect(
        HostHealthPolicy.iosIdleNotice(
          now: lastSeen.add(const Duration(seconds: 59)),
          sharingStartedAt: started,
          lastVisitorSeenAt: lastSeen,
          onlineCount: 0,
        ),
        isNull,
      );
      expect(
        HostHealthPolicy.iosIdleNotice(
          now: lastSeen.add(const Duration(minutes: 1)),
          sharingStartedAt: started,
          lastVisitorSeenAt: lastSeen,
          onlineCount: 0,
        ),
        isNotNull,
      );
      expect(
        HostHealthPolicy.iosIdleNotice(
          now: lastSeen.add(const Duration(minutes: 5)),
          sharingStartedAt: started,
          lastVisitorSeenAt: lastSeen,
          onlineCount: 1,
        ),
        isNull,
      );
    },
  );

  test('power notice only warns for actionable battery states', () {
    expect(
      HostHealthPolicy.powerNotice(
        const DevicePowerState(
          level: 0.20,
          charging: false,
          lowPowerMode: false,
        ),
      ),
      contains('20%'),
    );
    expect(
      HostHealthPolicy.powerNotice(
        const DevicePowerState(
          level: 0.10,
          charging: true,
          lowPowerMode: false,
        ),
      ),
      isNull,
    );
    expect(
      HostHealthPolicy.powerNotice(
        const DevicePowerState(
          level: null,
          charging: false,
          lowPowerMode: true,
        ),
      ),
      contains('低电量模式'),
    );
  });
}
