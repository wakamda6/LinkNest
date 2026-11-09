import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/host_network.dart';

void main() {
  test(
    'iOS prefers its real hotspot bridge over a connected Wi-Fi address',
    () {
      final selected = selectIosHostNetwork([
        {'interface': 'en4', 'kind': 'wifi', 'address': '192.168.1.25'},
        {'interface': 'bridge100', 'kind': 'hotspot', 'address': '172.20.10.1'},
      ]);
      expect(selected?.kind, HostNetworkKind.iosPersonalHotspot);
      expect(selected?.address, '172.20.10.1');
    },
  );

  test('iOS Wi-Fi accepts all RFC 1918 private ranges', () {
    expect(isIosHostWifiAddress('10.0.0.23'), isTrue);
    expect(isIosHostWifiAddress('10.255.255.254'), isTrue);
    expect(isIosHostWifiAddress('172.16.0.23'), isTrue);
    expect(isIosHostWifiAddress('172.31.255.23'), isTrue);
    expect(isIosHostWifiAddress('172.32.0.23'), isFalse);
    expect(isIosHostWifiAddress('192.168.0.23'), isTrue);
    final selected = selectIosHostNetwork([
      {'interface': 'en0', 'kind': 'wifi', 'address': '10.0.0.23'},
    ]);
    expect(selected?.kind, HostNetworkKind.iosWifi);
    expect(selected?.address, '10.0.0.23');
  });

  test('iOS does not treat a virtual private address as Wi-Fi', () {
    expect(
      selectIosHostNetwork([
        {'interface': 'utun0', 'kind': 'other', 'address': '192.168.1.23'},
        {'interface': 'bridge100', 'kind': 'other', 'address': '172.20.10.1'},
      ]),
      isNull,
    );
  });

  test('Android uses the newly created hotspot address', () {
    final selected = selectAndroidHostNetwork([
      {'interface': 'wlan0', 'priority': 40, 'address': '192.168.1.23'},
      {'interface': 'ap0', 'priority': 100, 'address': '192.168.43.1'},
    ]);
    expect(selected?.kind, HostNetworkKind.androidHotspot);
    expect(selected?.address, '192.168.43.1');
  });

  test('Android accepts a hotspot address in 10/8', () {
    final selected = selectAndroidHostNetwork([
      {'interface': 'ap0', 'priority': 100, 'address': '10.0.0.1'},
    ]);
    expect(selected?.kind, HostNetworkKind.androidHotspot);
    expect(selected?.address, '10.0.0.1');
  });

  test(
    'Android falls back to current Wi-Fi when no hotspot address exists',
    () {
      final selected = selectAndroidHostNetwork([
        {'interface': 'wlan0', 'priority': 40, 'address': '192.168.1.23'},
      ]);
      expect(selected?.kind, HostNetworkKind.androidWifi);
      expect(selected?.address, '192.168.1.23');
      expect(
        selectAndroidHotspotNetwork([
          {'interface': 'wlan0', 'priority': 40, 'address': '192.168.1.23'},
        ]),
        isNull,
      );
    },
  );

  test('Android manual retry requires a hotspot candidate', () {
    final wifiOnly = [
      {'interface': 'wlan0', 'priority': 40, 'address': '192.168.1.23'},
    ];
    expect(selectAndroidManualHotspotNetwork(wifiOnly), isNull);

    final hotspot = selectAndroidManualHotspotNetwork([
      {'interface': 'wlan2', 'priority': 100, 'address': '10.224.238.78'},
    ]);
    expect(hotspot?.kind, HostNetworkKind.manualHotspot);
    expect(hotspot?.interfaceName, 'wlan2');
  });
}
