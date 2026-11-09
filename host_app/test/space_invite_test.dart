import 'package:flutter_test/flutter_test.dart';
import 'package:linknest/space_invite.dart';

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789';

  group('SpaceInvite.parse', () {
    test('accepts only supported LAN IPv4 invite URLs', () {
      for (final host in [
        '10.0.0.1',
        '10.255.255.254',
        '172.16.4.1',
        '172.31.255.1',
        '192.168.1.1',
      ]) {
        final invite = SpaceInvite.parse('http://$host:8080/#token=$token');
        expect(invite.baseUri, Uri.parse('http://$host:8080/'));
        expect(invite.token, token);
      }
    });

    test('accepts surrounding whitespace', () {
      final invite = SpaceInvite.parse(
        '  http://192.168.43.1:8080/#token=$token  ',
      );
      expect(invite.baseUri.host, '192.168.43.1');
    });

    test('rejects unsafe or incomplete addresses', () {
      final invalid = [
        'https://192.168.1.1:8080/#token=$token',
        'http://example.com:8080/#token=$token',
        'http://8.8.8.8:8080/#token=$token',
        'http://192.168.1.1/#token=$token',
        'http://192.168.1.1:not-a-port/#token=$token',
        'http://user@192.168.1.1:8080/#token=$token',
        'http://192.168.1.1:8080/path#token=$token',
        'http://192.168.1.1:8080/?x=1#token=$token',
        'http://192.168.1.1:8080/',
        'http://192.168.1.1:8080/#token=short',
        'http://172.32.0.1:8080/#token=$token',
        'http://192.168.001.1:8080/#token=$token',
      ];

      for (final value in invalid) {
        expect(() => SpaceInvite.parse(value), throwsFormatException);
      }
    });
  });
}
