import 'dart:convert';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

void main() {
  test('Malformed or privileged WireGuard snapshot fields fail closed', () {
    final key = base64.encode(List.filled(32, 7));
    final c = AppController()
      ..addSubscription(
        name: 'Synthetic',
        raw: jsonEncode({
          'outbounds': [
            {
              'protocol': 'wireguard',
              'settings': {
                'secretKey': key,
                'address': ['10.7.0.2/32'],
                'peers': [
                  {'publicKey': key, 'endpoint': 'vpn.example:51820'},
                ],
              },
            },
          ],
        }),
      );
    addTearDown(c.dispose);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (p) => (p['wireguard'] as Map<String, dynamic>)['privateKey'] = 'invalid',
      (p) => (p['wireguard'] as Map<String, dynamic>)['noKernelTun'] = false,
      (p) =>
          (p['wireguard'] as Map<String, dynamic>)['addresses'] = ['0.0.0.0/0'],
      (p) => (p['wireguard'] as Map<String, dynamic>)['keepAlive'] = 121,
      (p) => p['transport'] = {'type': 'ws'},
      (p) => p['tls'] = {'enabled': true},
      (p) => p['password'] = 'unexpected',
    ]) {
      final snapshot =
          jsonDecode(jsonEncode(c.exportSnapshot())) as Map<String, dynamic>;
      mutate(snapshot['groups'][0]['profiles'][0] as Map<String, dynamic>);
      expect(
        () => AppController.fromSnapshot(snapshot),
        throwsA(isA<SnapshotFormatException>()),
      );
    }
  });
  test(
    'Proxy credentials, labels and WireGuard keys survive protected snapshots',
    () {
      final key = base64.encode(List.filled(32, 7));
      for (final raw in [
        'socks5://synthetic:password@vpn.example:1080',
        'https://synthetic:password@vpn.example:443',
        jsonEncode({
          'outbounds': [
            {
              'protocol': 'wireguard',
              'settings': {
                'secretKey': key,
                'address': ['10.7.0.2/32'],
                'peers': [
                  {'publicKey': key, 'endpoint': 'vpn.example:51820'},
                ],
              },
            },
          ],
        }),
      ]) {
        final c = AppController()..addSubscription(name: 'Synthetic', raw: raw);
        addTearDown(c.dispose);
        expect(c.groups.single.servers, hasLength(1));
        final restored = AppController.fromSnapshot(
          jsonDecode(jsonEncode(c.exportSnapshot())) as Map<String, dynamic>,
        );
        addTearDown(restored.dispose);
        expect(
          restored.selectedServer!.profile.toNativeJson(),
          c.selectedServer!.profile.toNativeJson(),
        );
        if (raw.startsWith('socks5')) {
          expect(restored.selectedServer!.protocolLabel, contains('без TLS'));
        }
        if (raw.startsWith('https')) {
          expect(
            restored.selectedServer!.protocolLabel,
            'HTTPS CONNECT · TCP · TLS',
          );
        }
      }
    },
  );
}
