import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart';

import 'native.dart';
import 'space_invite.dart';

const String linkNestDiscoveryServiceType = '_linknest._tcp';
const String _discoveryProtocolVersion = '1';

class DiscoveredSpace {
  const DiscoveredSpace({
    required this.spaceId,
    required this.name,
    required this.sessionId,
    required this.invites,
  });

  final String spaceId;
  final String name;
  final String sessionId;
  final List<SpaceInvite> invites;

  static DiscoveredSpace? fromNativeMap(Map<String, dynamic> value) {
    try {
      final addresses = (value['addresses'] as List? ?? const [])
          .whereType<String>()
          .map(InternetAddress.new)
          .toList();
      final txt = <String, Uint8List>{};
      for (final entry in (value['txt'] as Map? ?? const {}).entries) {
        if (entry.key is String && entry.value is String) {
          txt[entry.key as String] = Uint8List.fromList(
            utf8.encode(entry.value as String),
          );
        }
      }
      return fromService(
        Service(port: value['port'] as int?, addresses: addresses, txt: txt),
      );
    } catch (_) {
      return null;
    }
  }

  static DiscoveredSpace? fromService(Service service) {
    final port = service.port;
    final txt = service.txt;
    if (port == null || port < 1 || port > 65535 || txt == null) return null;
    try {
      final protocol = _txtValue(txt, 'pv');
      final spaceId = _txtValue(txt, 'sid');
      final name = _txtValue(txt, 'sname');
      final sessionId = _txtValue(txt, 'sess');
      final token = _txtValue(txt, 'token');
      if (protocol != _discoveryProtocolVersion ||
          spaceId.isEmpty ||
          name.trim().isEmpty ||
          sessionId.isEmpty) {
        return null;
      }

      final hosts = <String>{};
      if (txt.containsKey('addr')) {
        final selectedAddress = _txtValue(txt, 'addr');
        if (!SpaceInvite.isSupportedLanIpv4(selectedAddress)) return null;
        hosts.add(selectedAddress);
      } else {
        for (final address in service.addresses ?? const <InternetAddress>[]) {
          if (address.type == InternetAddressType.IPv4 &&
              SpaceInvite.isSupportedLanIpv4(address.address)) {
            hosts.add(address.address);
          }
        }
        final serviceHost = service.host;
        if (serviceHost != null &&
            SpaceInvite.isSupportedLanIpv4(serviceHost)) {
          hosts.add(serviceHost);
        }
      }
      final invites = <SpaceInvite>[];
      for (final host in hosts) {
        try {
          invites.add(
            SpaceInvite.parse(
              'http://$host:$port/#token=${Uri.encodeQueryComponent(token)}',
            ),
          );
        } on FormatException {
          // 忽略不符合局域网邀请格式的解析结果。
        }
      }
      if (invites.isEmpty) return null;
      return DiscoveredSpace(
        spaceId: spaceId,
        name: name.trim(),
        sessionId: sessionId,
        invites: List.unmodifiable(invites),
      );
    } on FormatException {
      return null;
    }
  }
}

class LinkNestDiscovery {
  const LinkNestDiscovery();

  Future<List<DiscoveredSpace>> findReachable({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = await findAll(timeout: timeout);
    if (found.isEmpty) return const [];
    final checks = await Future.wait(found.map(_checkReachable));
    return checks.whereType<DiscoveredSpace>().toList(growable: false);
  }

  Future<DiscoveredSpace?> _checkReachable(DiscoveredSpace space) async {
    for (final invite in space.invites) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 900)
        ..findProxy = (_) => 'DIRECT';
      try {
        final request = await client
            .getUrl(invite.baseUri.resolve('/api/discovery'))
            .timeout(const Duration(milliseconds: 1200));
        final response = await request.close().timeout(
          const Duration(milliseconds: 1200),
        );
        if (response.statusCode != HttpStatus.ok) continue;
        final body = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(milliseconds: 1200));
        final envelope = jsonDecode(body);
        if (envelope is! Map || envelope['data'] is! Map) continue;
        final data = envelope['data'] as Map;
        if (data['spaceId'] == space.spaceId &&
            data['sessionId'] == space.sessionId) {
          debugPrint('[LinkNest] 局域网空间地址已核验 id=${space.spaceId}');
          return space;
        }
      } catch (error) {
        debugPrint('[LinkNest] 局域网空间地址不可达 reason=${error.runtimeType}');
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<DiscoveredSpace?> find({
    Duration timeout = const Duration(seconds: 3),
  }) async => (await findAll(timeout: timeout)).firstOrNull;

  Future<List<DiscoveredSpace>> findAll({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (Platform.isAndroid) {
      try {
        final found = await LinkNestNative().discoverSpaces(timeout: timeout);
        return found
            .map(DiscoveredSpace.fromNativeMap)
            .whereType<DiscoveredSpace>()
            .toList();
      } catch (error) {
        debugPrint('[LinkNest] Android 局域网发现失败 reason=${error.runtimeType}');
        return const [];
      }
    }
    Discovery? discovery;
    VoidCallback? listener;
    try {
      debugPrint('[LinkNest] 开始搜索当前局域网内的空间');
      discovery = await startDiscovery(
        linkNestDiscoveryServiceType,
        ipLookupType: IpLookupType.v4,
      );
      final found = <String, DiscoveredSpace>{};
      void inspect() {
        for (final service in discovery!.services) {
          final space = DiscoveredSpace.fromService(service);
          if (space != null) {
            found['${space.spaceId}:${space.sessionId}'] = space;
          }
        }
      }

      listener = inspect;
      discovery.addListener(listener);
      inspect();
      await Future<void>.delayed(timeout);
      inspect();
      debugPrint('[LinkNest] 局域网搜索结束 count=${found.length}');
      return found.values.toList(growable: false);
    } catch (error) {
      debugPrint('[LinkNest] 搜索局域网空间失败 reason=${error.runtimeType}');
      return const [];
    } finally {
      if (discovery != null) {
        if (listener != null) discovery.removeListener(listener);
        try {
          await stopDiscovery(discovery);
        } catch (error) {
          debugPrint('[LinkNest] 停止局域网空间搜索失败 reason=${error.runtimeType}');
        }
      }
    }
  }
}

class LinkNestDiscoveryAdvertiser {
  LinkNestDiscoveryAdvertiser({
    Future<Registration> Function(Service service)? registerService,
    Future<void> Function(Registration registration)? unregisterService,
  }) : _registerService = registerService ?? register,
       _unregisterService = unregisterService ?? unregister;

  final Future<Registration> Function(Service service) _registerService;
  final Future<void> Function(Registration registration) _unregisterService;
  Registration? _registration;
  int _generation = 0;
  bool _advertisementDesired = false;

  Future<void> start({
    required String spaceId,
    required String spaceName,
    required String sessionId,
    required String token,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await close();
    final generation = ++_generation;
    _advertisementDesired = true;
    final service = Service(
      name: 'LinkNest-${_safeServiceSuffix(spaceId)}',
      type: linkNestDiscoveryServiceType,
      port: port,
      txt: {
        'pv': _txtBytes(_discoveryProtocolVersion),
        'sid': _txtBytes(spaceId),
        'sname': _txtBytes(spaceName),
        'sess': _txtBytes(sessionId),
        'token': _txtBytes(token),
      },
    );
    final registrationFuture = _registerService(service);
    debugPrint(
      '[LinkNest] 开始发布局域网空间 id=$spaceId port=$port '
      'generation=$generation',
    );
    try {
      final registration = await registrationFuture.timeout(timeout);
      await _acceptRegistration(
        registration,
        generation: generation,
        spaceId: spaceId,
        late: false,
      );
    } on TimeoutException {
      debugPrint('[LinkNest] 局域网空间广播注册超时');
      unawaited(
        _handleLateRegistration(
          registrationFuture,
          generation: generation,
          spaceId: spaceId,
        ),
      );
      rethrow;
    }
  }

  Future<void> _handleLateRegistration(
    Future<Registration> registrationFuture, {
    required int generation,
    required String spaceId,
  }) async {
    try {
      final registration = await registrationFuture;
      await _acceptRegistration(
        registration,
        generation: generation,
        spaceId: spaceId,
        late: true,
      );
    } catch (error) {
      debugPrint(
        '[LinkNest] 延迟的局域网广播注册已结束 '
        'reason=${error.runtimeType}',
      );
    }
  }

  Future<void> _acceptRegistration(
    Registration registration, {
    required int generation,
    required String spaceId,
    required bool late,
  }) async {
    if (!_advertisementDesired || generation != _generation) {
      await _unregisterSafely(registration, late: late);
      return;
    }
    _registration = registration;
    debugPrint(
      late
          ? '[LinkNest] 已接受延迟的局域网广播 id=$spaceId'
          : '[LinkNest] 局域网空间已发布 id=$spaceId',
    );
  }

  Future<void> _unregisterSafely(
    Registration registration, {
    required bool late,
  }) async {
    try {
      await _unregisterService(registration);
      debugPrint(late ? '[LinkNest] 已清理过期的延迟广播' : '[LinkNest] 已清理过期广播');
    } catch (error) {
      debugPrint('[LinkNest] 清理过期局域网广播失败 reason=${error.runtimeType}');
    }
  }

  Future<void> close() async {
    _advertisementDesired = false;
    _generation++;
    final registration = _registration;
    _registration = null;
    if (registration == null) return;
    try {
      await _unregisterService(registration);
      debugPrint('[LinkNest] 局域网空间广播已停止');
    } catch (error) {
      debugPrint('[LinkNest] 停止局域网空间广播失败 reason=${error.runtimeType}');
    }
  }
}

Uint8List _txtBytes(String value) => Uint8List.fromList(utf8.encode(value));

String _txtValue(Map<String, Uint8List?> txt, String key) {
  final bytes = txt[key];
  if (bytes == null || bytes.isEmpty || bytes.length > 255) {
    throw const FormatException('invalid discovery field');
  }
  return utf8.decode(bytes, allowMalformed: false);
}

String _safeServiceSuffix(String spaceId) {
  final safe = spaceId.replaceAll(RegExp('[^A-Za-z0-9-]'), '-');
  return safe.length <= 40 ? safe : safe.substring(safe.length - 40);
}
