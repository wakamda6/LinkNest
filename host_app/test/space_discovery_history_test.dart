import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/guest_space_history.dart';
import 'package:linknest/space_discovery.dart';
import 'package:linknest/space_invite.dart';
import 'package:nsd/nsd.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789';

  group('local space discovery records', () {
    test('accepts a valid service and keeps only private IPv4 addresses', () {
      final result = DiscoveredSpace.fromService(
        Service(
          name: 'LinkNest-space-1',
          type: linkNestDiscoveryServiceType,
          port: 8080,
          addresses: [
            InternetAddress('192.168.43.1'),
            InternetAddress('10.0.0.1'),
            InternetAddress('8.8.8.8'),
          ],
          txt: {
            'pv': _bytes('1'),
            'sid': _bytes('space-1'),
            'sname': _bytes('周末旅行'),
            'sess': _bytes('session-1'),
            'token': _bytes(token),
          },
        ),
      );

      expect(result?.spaceId, 'space-1');
      expect(result?.name, '周末旅行');
      expect(result?.invites, hasLength(2));
      expect(result?.invites.map((invite) => invite.baseUri.host), [
        '192.168.43.1',
        '10.0.0.1',
      ]);
    });

    test(
      'uses the selected 10/8 address even when another address resolves',
      () {
        final result = DiscoveredSpace.fromService(
          Service(
            port: 8080,
            addresses: [InternetAddress('192.168.43.1')],
            txt: {
              'pv': _bytes('1'),
              'sid': _bytes('space-1'),
              'sname': _bytes('周末旅行'),
              'sess': _bytes('session-1'),
              'token': _bytes(token),
              'addr': _bytes('10.0.0.1'),
            },
          ),
        );
        expect(result?.invites.single.baseUri.host, '10.0.0.1');
      },
    );

    test('rejects incomplete records and public-only addresses', () {
      expect(
        DiscoveredSpace.fromService(
          Service(
            port: 8080,
            addresses: [InternetAddress('8.8.8.8')],
            txt: {
              'pv': _bytes('1'),
              'sid': _bytes('space-1'),
              'sname': _bytes('周末旅行'),
              'sess': _bytes('session-1'),
              'token': _bytes(token),
            },
          ),
        ),
        isNull,
      );
      expect(
        DiscoveredSpace.fromService(
          Service(
            port: 8080,
            addresses: [InternetAddress('192.168.43.1')],
            txt: {'pv': _bytes('1')},
          ),
        ),
        isNull,
      );
    });

    test(
      'prefers the Host-selected interface address over other interfaces',
      () {
        final result = DiscoveredSpace.fromService(
          Service(
            port: 8080,
            addresses: [InternetAddress('192.168.1.25')],
            txt: {
              'pv': _bytes('1'),
              'sid': _bytes('space-1'),
              'sname': _bytes('周末旅行'),
              'sess': _bytes('session-1'),
              'token': _bytes(token),
              'addr': _bytes('172.20.10.1'),
            },
          ),
        );
        expect(result?.invites.single.baseUri.host, '172.20.10.1');
      },
    );

    test(
      'advertisement registration times out instead of blocking Host',
      () async {
        final pending = Completer<Registration>();
        final advertiser = LinkNestDiscoveryAdvertiser(
          registerService: (_) => pending.future,
        );

        await expectLater(
          advertiser.start(
            spaceId: 'space-1',
            spaceName: '周末旅行',
            sessionId: 'session-1',
            token: token,
            port: 8080,
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test(
      'keeps a late registration while the Host session is active',
      () async {
        final pending = Completer<Registration>();
        final unregistered = <Registration>[];
        late Service requestedService;
        final advertiser = LinkNestDiscoveryAdvertiser(
          registerService: (service) {
            requestedService = service;
            return pending.future;
          },
          unregisterService: (registration) async {
            unregistered.add(registration);
          },
        );

        await expectLater(
          advertiser.start(
            spaceId: 'space-1',
            spaceName: '周末旅行',
            sessionId: 'session-1',
            token: token,
            port: 8080,
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(isA<TimeoutException>()),
        );

        final registration = Registration('late-active', requestedService);
        pending.complete(registration);
        await Future<void>.delayed(Duration.zero);

        expect(unregistered, isEmpty);
        await advertiser.close();
        expect(unregistered, [registration]);
      },
    );

    test('removes a late registration after the Host session closes', () async {
      final pending = Completer<Registration>();
      final unregistered = <Registration>[];
      late Service requestedService;
      final advertiser = LinkNestDiscoveryAdvertiser(
        registerService: (service) {
          requestedService = service;
          return pending.future;
        },
        unregisterService: (registration) async {
          unregistered.add(registration);
        },
      );

      await expectLater(
        advertiser.start(
          spaceId: 'space-1',
          spaceName: '周末旅行',
          sessionId: 'session-1',
          token: token,
          port: 8080,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await advertiser.close();

      final registration = Registration('late-closed', requestedService);
      pending.complete(registration);
      await Future<void>.delayed(Duration.zero);

      expect(unregistered, [registration]);
    });
  });

  group('recent guest spaces', () {
    test('loads an old 10/8 guest record', () async {
      SharedPreferences.setMockInitialValues({
        'guest_recent_spaces_v1': jsonEncode([
          {
            'spaceId': 'old-10',
            'name': '旧空间',
            'inviteUrl': 'http://10.0.0.1:8080/#token=$token',
            'lastJoinedAt': 1,
          },
          {
            'spaceId': 'allowed',
            'name': '可用空间',
            'inviteUrl': 'http://192.168.43.1:8080/#token=$token',
            'lastJoinedAt': 2,
          },
        ]),
      });
      final history = await GuestSpaceHistory.open();
      expect(history.spaces.map((space) => space.spaceId), [
        'allowed',
        'old-10',
      ]);
    });

    test(
      'removes only the selected record, persists, and allows rejoining',
      () async {
        SharedPreferences.setMockInitialValues({});
        final removedCaches = <String>[];
        final history = await GuestSpaceHistory.open(
          cacheRemover: (spaceId) async => removedCaches.add(spaceId),
        );
        final invite = SpaceInvite.parse(
          'http://192.168.43.1:8080/#token=$token',
        );
        await history.remember(spaceId: 'first', name: '同名相聚', invite: invite);
        final newer = await GuestSpaceHistory.open();
        await newer.remember(spaceId: 'second', name: '同名相聚', invite: invite);

        // 即使使用较早打开的实例删除，也保留后来新增的其他空间。
        await history.remove('first');
        expect(removedCaches, ['first']);
        final restored = await GuestSpaceHistory.open();
        expect(restored.spaces.map((s) => s.spaceId), ['second']);
        await restored.remove('missing');
        expect(
          (await GuestSpaceHistory.open()).spaces.single.spaceId,
          'second',
        );

        await restored.remember(spaceId: 'first', name: '再次相聚', invite: invite);
        final rejoined = await GuestSpaceHistory.open();
        expect(rejoined.spaces.map((s) => s.spaceId), ['first', 'second']);
        expect(rejoined.spaces.first.name, '再次相聚');
      },
    );

    test(
      'keeps all unique spaces beyond five and restores updated addresses',
      () async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final history = await GuestSpaceHistory.open(preferences: preferences);

        for (var index = 0; index < 6; index++) {
          await history.remember(
            spaceId: 'space-$index',
            name: '空间 $index',
            invite: SpaceInvite.parse('http://192.168.43.1:8080/#token=$token'),
            joinedAt: DateTime.utc(2026, 9, 24, index),
          );
        }

        expect(history.spaces, hasLength(6));
        expect(history.spaces.first.spaceId, 'space-5');
        expect(history.spaces.last.spaceId, 'space-0');

        await history.remember(
          spaceId: 'space-3',
          name: '更新后的空间',
          invite: SpaceInvite.parse('http://192.168.43.2:8080/#token=$token'),
          joinedAt: DateTime.utc(2026, 9, 25),
        );
        final restored = await GuestSpaceHistory.open(preferences: preferences);

        expect(restored.spaces, hasLength(6));
        expect(restored.spaces.first.spaceId, 'space-3');
        expect(restored.spaces.first.name, '更新后的空间');
        expect(restored.spaces.first.invite.baseUri.host, '192.168.43.2');
      },
    );

    test('keeps the participation record when cache cleanup fails', () async {
      SharedPreferences.setMockInitialValues({});
      final history = await GuestSpaceHistory.open(
        cacheRemover: (_) async => throw FileSystemException('cache busy'),
      );
      await history.remember(
        spaceId: 'space-1',
        name: '周末旅行',
        invite: SpaceInvite.parse('http://192.168.43.1:8080/#token=$token'),
      );

      await expectLater(
        history.remove('space-1'),
        throwsA(isA<FileSystemException>()),
      );
      expect((await GuestSpaceHistory.open()).spaces.single.spaceId, 'space-1');
    });
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));
