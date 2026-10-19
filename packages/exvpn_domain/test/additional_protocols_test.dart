import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

final key = base64.encode(List.filled(32, 7));
Map<String, Object?> wireguard() => {
  'protocol': 'wireguard',
  'settings': {
    'secretKey': key,
    'address': ['10.7.0.2/32', 'fd00:7::2/128'],
    'peers': [
      {'publicKey': key, 'endpoint': 'vpn.example:51820'},
    ],
  },
};
ImportResult parse(Map<String, Object?> value) =>
    const SubscriptionParser().parse(
      jsonEncode({
        'outbounds': [value],
      }),
    );
void main() {
  test(
    'Bounded WireGuard config ignores DNS and rejects hooks and multiple peers',
    () {
      final text =
          '[Interface]\nPrivateKey = $key\nAddress = 10.7.0.2/32, fd00:7::2/128\nDNS = 1.1.1.1\n[Peer]\nPublicKey = $key\nEndpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n';
      final r = const SubscriptionParser().parse(text);
      expect(r.profiles.single.wireguard!.keepAlive, 25);
      expect(r.issues.single.code, ImportIssueCode.ignoredLocalConfiguration);
      expect(
        const SubscriptionParser()
            .parse(
              text.replaceFirst('DNS = 1.1.1.1', 'PostUp = external-command'),
            )
            .profiles,
        isEmpty,
      );
      expect(
        const SubscriptionParser()
            .parse('$text[Peer]\nPublicKey = $key')
            .profiles,
        isEmpty,
      );
    },
  );
  test('proxy URLs normalize authenticated and anonymous variants', () {
    for (final scheme in ['socks5', 'socks', 'http', 'https']) {
      final r = const SubscriptionParser().parse(
        '$scheme://test:pass%3Aword@vpn.example:8443#Proxy',
      );
      expect(r.issues, isEmpty);
      final p = r.profiles.single;
      expect(p.username, 'test');
      expect(p.password, 'pass:word');
      expect(p.tls.enabled, scheme == 'https');
      expect(
        p.protocol,
        scheme.startsWith('socks') ? ProxyProtocol.socks5 : ProxyProtocol.http,
      );
    }
    expect(
      const SubscriptionParser()
          .parse('socks5://vpn.example:1080')
          .profiles
          .single
          .username,
      isNull,
    );
  });
  test(
    'proxy JSON accepts strict endpoint fields but rejects insecure TLS and detours',
    () {
      final r = parse({
        'protocol': 'http',
        'settings': {
          'servers': [
            {
              'address': 'vpn.example',
              'port': 443,
              'users': [
                {'user': 'u', 'pass': 'p'},
              ],
            },
          ],
        },
        'streamSettings': {
          'security': 'tls',
          'tlsSettings': {'serverName': 'vpn.example'},
        },
      });
      expect(r.issues, isEmpty);
      expect(r.profiles.single.tls.enabled, isTrue);
      expect(
        parse({
          'protocol': 'socks',
          'settings': {
            'servers': [
              {'address': 'vpn.example', 'port': 1080},
            ],
          },
          'streamSettings': {
            'security': 'tls',
            'tlsSettings': {'allowInsecure': true},
          },
        }).profiles,
        isEmpty,
      );
      expect(
        parse({
          'type': 'socks',
          'tag': 'Proxy',
          'server': 'vpn.example',
          'server_port': 1080,
          'version': '4',
        }).profiles,
        isEmpty,
      );
      expect(
        parse({
          'type': 'http',
          'server': 'vpn.example',
          'server_port': 443,
          'tls': {'enabled': true, 'server_name': 'vpn.example'},
        }).profiles.single.protocol,
        ProxyProtocol.http,
      );
    },
  );
  test(
    'WireGuard has one peer and typed tunnel addresses, never OS policy',
    () {
      final p = parse(wireguard()).profiles.single;
      expect(p.wireguard!.addresses, ['10.7.0.2/32', 'fd00:7::2/128']);
      expect(p.server, 'vpn.example');
      expect(p.port, 51820);
      expect(p.toNativeJson()['wireguard'], isA<Map<String, Object?>>());
      final sing = parse({
        'type': 'wireguard',
        'server': 'vpn.example',
        'server_port': 51820,
        'private_key': key,
        'peer_public_key': key,
        'local_address': ['10.7.0.2/32'],
        'reserved': [1, 2, 3],
      });
      expect(sing.issues, isEmpty);
      expect(sing.profiles.single.wireguard!.reserved, [1, 2, 3]);
      for (final mutation in <void Function(Map<String, Object?>)>[
        (s) => s['noKernelTun'] = false,
        (s) => s['secretKey'] = base64.encode(List.filled(32, 0)),
        (s) => s['address'] = ['0.0.0.0/0'],
        (s) => s['reserved'] = [256, 0, 0],
        (s) => s['remoteDNS'] = ['1.1.1.1'],
        (s) => s['mtu'] = 9000,
        (s) => s['peers'] = [
          {
            'publicKey': key,
            'endpoint': 'vpn.example:51820',
            'allowedIPs': ['10.0.0.0/8'],
          },
        ],
        (s) => s['peers'] = [
          {'publicKey': key, 'endpoint': 'vpn.example:51820'},
          {'publicKey': key, 'endpoint': 'backup.example:51820'},
        ],
      ]) {
        final v = wireguard();
        mutation(v['settings']! as Map<String, Object?>);
        expect(parse(v).profiles, isEmpty);
      }
    },
  );
  test(
    'additional options remain secret in text representation and affect identity',
    () {
      final a = const SubscriptionParser()
          .parse('socks5://one:password@vpn.example:1080')
          .profiles
          .single;
      final b = const SubscriptionParser()
          .parse('socks5://two:password@vpn.example:1080')
          .profiles
          .single;
      expect(a.id, isNot(b.id));
      expect(a.toString(), isNot(contains('password')));
      expect(
        parse(wireguard()).profiles.single.wireguard.toString(),
        isNot(contains(key)),
      );
    },
  );
}
