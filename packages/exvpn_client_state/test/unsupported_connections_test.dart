import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const _supported =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Working';
const _unsupported = 'tuic://synthetic-secret@private.invalid:443#Tokyo';

void main() {
  test(
    'unsupported rows never become profiles, selection or automatic candidates',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app.addSubscription(raw: '$_supported\n$_unsupported').groupId;
      final group = app.groups.single;
      expect(group.unsupportedConnections.single.displayName, 'Tokyo');
      expect(group.servers, hasLength(1));
      expect(app.selectedServer!.name, 'Working');
      expect(app.selectAutomaticGroup(id), isFalse);
      expect(app.selectServer(groupId: id, serverId: 'unsupported-2'), isFalse);
      final snapshot = jsonEncode(app.exportSnapshot());
      expect(snapshot, isNot(contains('synthetic-secret')));
      expect(snapshot, isNot(contains('private.invalid')));
      final restored = AppController.fromSnapshot(
        jsonDecode(snapshot) as Map<String, dynamic>,
      );
      addTearDown(restored.dispose);
      expect(restored.groups.single.unsupportedConnections, hasLength(1));
      expect(restored.selectedServer!.name, 'Working');
      expect(restored.exportSnapshot()['version'], 3);
    },
  );

  test('unsupported-only import is visible without a selected connection', () {
    final app = AppController();
    addTearDown(app.dispose);
    app.addSubscription(raw: _unsupported);
    expect(
      app.groups.single.unsupportedConnections.single.displayName,
      'Tokyo',
    );
    expect(app.groups.single.servers, isEmpty);
    expect(app.selectedServer, isNull);
  });

  test('refresh replaces disabled rows and clears them once supported', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app.addSubscription(raw: '$_supported\n$_unsupported').groupId;
    expect(
      app.updateSubscription(groupId: id, raw: _supported).applied,
      isTrue,
    );
    expect(app.groups.single.unsupportedConnections, isEmpty);
    app.updateSubscription(groupId: id, raw: _unsupported);
    expect(app.selectedServer!.name, 'Working');
    expect(
      app.groups.single.unsupportedConnections.single.displayName,
      'Tokyo',
    );
  });
}
