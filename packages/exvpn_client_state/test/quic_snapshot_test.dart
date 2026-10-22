// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

void main() {
  AppController imported() => AppController()
    ..addSubscription(
      name: 'Example',
      raw: Uri(
        scheme: 'hysteria2',
        userInfo: 'synthetic-password',
        host: 'node.example',
        port: 443,
        queryParameters: {
          'sni': 'front.example',
          'fm': jsonEncode({
            'quicParams': {
              'debug': false,
              'congestion': 'bbr',
              'maxIdleTimeout': 10,
              'keepAlivePeriod': 5,
            },
          }),
        },
      ).toString(),
    );
  Map<String, dynamic> snapshot(AppController app) =>
      jsonDecode(jsonEncode(app.exportSnapshot())) as Map<String, dynamic>;
  test(
    'Hysteria2 QUIC settings survive restart without defaults or losing selection',
    () {
      final app = imported();
      addTearDown(app.dispose);
      expect(app.groups.single.issues, isEmpty);
      final restored = AppController.fromSnapshot(snapshot(app));
      addTearDown(restored.dispose);
      expect(
        restored.selectedServer!.profile.toNativeJson(),
        app.selectedServer!.profile.toNativeJson(),
      );
      expect(restored.selectedServerId, app.selectedServerId);
    },
  );
  test(
    'stored tuning rejects foreign protocols, unknown fields and invalid bounds',
    () {
      final app = imported();
      addTearDown(app.dispose);
      for (final mutation in [
        'protocol',
        'unknown',
        'null',
        'bounds',
        'debug',
      ]) {
        final value = snapshot(app);
        final profile = value['groups'][0]['profiles'][0];
        final parameters = profile['transport']['quicParams'];
        switch (mutation) {
          case 'protocol':
            profile['protocol'] = 'vless';
          case 'unknown':
            parameters['allowInsecure'] = true;
          case 'null':
            profile['transport']['quicParams'] = null;
          case 'bounds':
            parameters['maxIdleTimeout'] = -1;
          case 'debug':
            parameters['debug'] = true;
        }
        expect(
          () => AppController.fromSnapshot(value),
          throwsA(isA<SnapshotFormatException>()),
        );
      }
    },
  );
}
