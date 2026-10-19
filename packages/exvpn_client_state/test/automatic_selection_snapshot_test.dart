import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const node = 'vless://00000000-0000-4000-8000-000000000001';

AppController group() => AppController()
  ..addSubscription(
    raw:
        '$node@first.example:443?security=tls#Primary\n'
        '$node@second.example:443?security=tls#Backup',
  );

Map<String, dynamic> snapshot(AppController app) =>
    jsonDecode(jsonEncode(app.exportSnapshot())) as Map<String, dynamic>;

void main() {
  test(
    'automatic intent is explicit, survives storage, manual choice clears it',
    () {
      final app = group();
      addTearDown(app.dispose);
      expect(app.selectedAutomaticGroupId, isNull);
      final id = app.groups.single.id;
      expect(app.selectAutomaticGroup(id), isTrue);
      final restored = AppController.fromSnapshot(snapshot(app));
      addTearDown(restored.dispose);
      expect(restored.selectedAutomaticGroupId, id);
      expect(restored.selectedServer!.profile.server, 'first.example');
      restored.selectServer(groupId: id, serverId: restored.selectedServerId!);
      expect(restored.selectedAutomaticGroupId, isNull);
    },
  );

  test(
    'refresh reducing group to one clears intent; removal cannot transfer it',
    () {
      final app = group();
      addTearDown(app.dispose);
      final id = app.groups.single.id;
      app.selectAutomaticGroup(id);
      app.updateSubscription(
        groupId: id,
        raw: '$node@first.example:443?security=tls',
      );
      expect(app.selectedAutomaticGroupId, isNull);
      expect(app.selectAutomaticGroup(id), isFalse);
      app.removeSubscription(id);
      expect(app.selectedAutomaticGroupId, isNull);
    },
  );

  test('old snapshots still restore without enabling automatic connection', () {
    final app = group();
    addTearDown(app.dispose);
    final old = snapshot(app)..['version'] = 2;
    old.remove('selectedAutomaticGroupId');
    final restored = AppController.fromSnapshot(old);
    addTearDown(restored.dispose);
    expect(restored.selectedAutomaticGroupId, isNull);
    expect(restored.groups.single.servers, hasLength(2));
  });

  test(
    'extended transport and packet encoding survive encrypted snapshot boundary',
    () {
      final app = AppController()
        ..addSubscription(
          raw: jsonEncode({
            'outbounds': [
              {
                'type': 'vless',
                'tag': 'Synthetic',
                'server': 'first.example',
                'server_port': 443,
                'uuid': '00000000-0000-4000-8000-000000000001',
                'packet_encoding': 'xudp',
                'tls': {'enabled': true, 'server_name': 'first.example'},
                'transport': {
                  'type': 'ws',
                  'path': '/',
                  'early_data_header_name': 'Sec-WebSocket-Protocol',
                },
              },
            ],
          }),
        );
      addTearDown(app.dispose);
      expect(app.selectedServer, isNotNull);
      final data = snapshot(app);
      final transport = data['groups'][0]['profiles'][0]['transport'] as Map;
      transport['tcpKeepAliveIdle'] = 60;
      transport['tcpKeepAliveInterval'] = 20;
      final restored = AppController.fromSnapshot(data);
      addTearDown(restored.dispose);
      final profile = restored.selectedServer!.profile;
      expect(profile.packetEncoding, 'xudp');
      expect(profile.transport.wsEarlyDataHeaderName, 'Sec-WebSocket-Protocol');
      expect(profile.transport.tcpKeepAliveIdle, 60);
      expect(profile.transport.tcpKeepAliveInterval, 20);
      for (final invalid in [0, -1, 86401, '60', 1.5]) {
        transport['tcpKeepAliveIdle'] = invalid;
        expect(
          () => AppController.fromSnapshot(data),
          throwsA(isA<SnapshotFormatException>()),
        );
      }
    },
  );
}
