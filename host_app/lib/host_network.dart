import 'space_invite.dart';

enum HostNetworkKind {
  androidHotspot,
  androidWifi,
  iosPersonalHotspot,
  iosWifi,
  manualHotspot,
}

class HostNetwork {
  const HostNetwork({
    required this.kind,
    required this.address,
    required this.interfaceName,
  });

  final HostNetworkKind kind;
  final String address;
  final String interfaceName;
}

/// Host and Guest accept RFC 1918 private IPv4 addresses on every platform.
bool isIosHostWifiAddress(String value) =>
    SpaceInvite.isSupportedLanIpv4(value);

HostNetwork? selectIosHostNetwork(List<Map<String, dynamic>> addresses) {
  for (final item in addresses) {
    final address = item['address']?.toString() ?? '';
    final name = item['interface']?.toString() ?? '';
    if (item['kind'] == 'hotspot' &&
        name.startsWith('bridge') &&
        address == '172.20.10.1') {
      return HostNetwork(
        kind: HostNetworkKind.iosPersonalHotspot,
        address: address,
        interfaceName: name,
      );
    }
  }
  for (final item in addresses) {
    final address = item['address']?.toString() ?? '';
    if (item['kind'] == 'wifi' && isIosHostWifiAddress(address)) {
      return HostNetwork(
        kind: HostNetworkKind.iosWifi,
        address: address,
        interfaceName: item['interface']?.toString() ?? '',
      );
    }
  }
  return null;
}

HostNetwork? selectAndroidHostNetwork(List<Map<String, dynamic>> addresses) {
  for (final item in addresses) {
    final address = item['address']?.toString() ?? '';
    final priority = item['priority'];
    if (priority is int &&
        priority >= 80 &&
        SpaceInvite.isSupportedLanIpv4(address)) {
      return HostNetwork(
        kind: HostNetworkKind.androidHotspot,
        address: address,
        interfaceName: item['interface']?.toString() ?? '',
      );
    }
  }
  for (final item in addresses) {
    final address = item['address']?.toString() ?? '';
    final priority = item['priority'];
    if (priority is int &&
        priority >= 40 &&
        SpaceInvite.isSupportedLanIpv4(address)) {
      return HostNetwork(
        kind: HostNetworkKind.androidWifi,
        address: address,
        interfaceName: item['interface']?.toString() ?? '',
      );
    }
  }
  return null;
}

HostNetwork? selectAndroidWifiNetwork(List<Map<String, dynamic>> addresses) {
  for (final item in addresses) {
    final priority = item['priority'];
    final address = item['address']?.toString() ?? '';
    if ((item['networkType'] == 'wifi' || priority == 40) &&
        SpaceInvite.isSupportedLanIpv4(address)) {
      return HostNetwork(
        kind: HostNetworkKind.androidWifi,
        address: address,
        interfaceName: item['interface']?.toString() ?? '',
      );
    }
  }
  return null;
}

HostNetwork? selectAndroidHotspotNetwork(List<Map<String, dynamic>> addresses) {
  final selected = selectAndroidHostNetwork(addresses);
  if (selected == null || selected.kind != HostNetworkKind.androidHotspot) {
    return null;
  }
  return selected;
}

HostNetwork? selectAndroidManualHotspotNetwork(
  List<Map<String, dynamic>> addresses,
) {
  final selected = selectAndroidHotspotNetwork(addresses);
  if (selected == null) return null;
  return HostNetwork(
    kind: HostNetworkKind.manualHotspot,
    address: selected.address,
    interfaceName: selected.interfaceName,
  );
}
