import 'dart:convert';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

void main() {
  AppController fixture() => AppController()
    ..addSubscription(
      name: 'Synthetic MASQUE',
      raw: jsonEncode({
        'outbounds': [
          {
            'protocol': 'masque',
            'settings': {'address': 'vpn.example', 'port': 443},
            'streamSettings': {
              'network': 'masque',
              'security': 'tls',
              'masqueSettings': {'user': 'synthetic', 'pass': 'password'},
              'tlsSettings': {
                'serverName': 'vpn.example',
                'alpn': ['h3'],
              },
            },
          },
        ],
      }),
    );

  test('Authenticated MASQUE survives snapshot and has one protocol label', () {
    final state = fixture();
    addTearDown(state.dispose);
    expect(state.groups.single.servers, hasLength(1));
    final restored = AppController.fromSnapshot(
      jsonDecode(jsonEncode(state.exportSnapshot())) as Map<String, dynamic>,
    );
    addTearDown(restored.dispose);
    expect(
      restored.selectedServer!.profile.toNativeJson(),
      state.selectedServer!.profile.toNativeJson(),
    );
    expect(restored.selectedServer!.protocolLabel, 'MASQUE');
  });

  test('Snapshot cannot bypass MASQUE authentication or TLS policy', () {
    final state = fixture();
    addTearDown(state.dispose);
    for (final change in <void Function(Map<String, dynamic>)>[
      (p) => p.remove('username'),
      (p) => p['username'] = 'name:other',
      (p) => p['password'] = '',
      (p) => p['password'] = 'line\nother',
      (p) => p['transport'] = {'type': 'tcp'},
      (p) => p['transport'] = {'type': 'masque', 'path': '/custom'},
      (p) => p['tls']['enabled'] = false,
      (p) => p['tls'].remove('serverName'),
      (p) => p['tls']['alpn'] = ['h2'],
      (p) => p['tls']['fingerprint'] = 'chrome',
      (p) => p['tls']['reality'] = {'publicKey': 'unexpected'},
      (p) => p['uuid'] = 'unexpected',
    ]) {
      final snapshot =
          jsonDecode(jsonEncode(state.exportSnapshot()))
              as Map<String, dynamic>;
      change(snapshot['groups'][0]['profiles'][0] as Map<String, dynamic>);
      expect(
        () => AppController.fromSnapshot(snapshot),
        throwsA(isA<SnapshotFormatException>()),
      );
    }
  });
}
