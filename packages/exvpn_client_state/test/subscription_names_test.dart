import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const _node =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#One';

Map<String, dynamic> _snapshot(AppController app) =>
    jsonDecode(jsonEncode(app.exportSnapshot())) as Map<String, dynamic>;

void main() {
  test('optional name uses provider metadata and a safe unnamed fallback', () {
    final app = AppController();
    addTearDown(app.dispose);
    app.addSubscription(raw: _node, providerName: '  Северный VPN  ');
    app.addSubscription(
      raw: _node,
      sourceUrl: 'https://sample.invalid/private',
    );
    expect(app.groups.first.name, 'Северный VPN');
    expect(app.groups.first.nameIsAutomatic, isTrue);
    expect(app.groups.last.name, 'Подписка');
  });

  test('automatic provider name refreshes with accepted content only', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app.addSubscription(raw: _node, providerName: 'First').groupId;
    app.updateSubscription(
      groupId: id,
      raw: 'broken',
      providerName: 'Rejected',
    );
    expect(app.groups.single.name, 'First');
    expect(app.groups.single.providerName, 'First');
    app.updateSubscription(groupId: id, raw: _node, providerName: 'Second');
    expect(app.groups.single.name, 'Second');
    app.updateSubscription(groupId: id, raw: _node);
    expect(app.groups.single.name, 'Second');
    expect(app.groups.single.providerName, 'Second');
  });

  test('manual name survives refresh and protected snapshot round trip', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app
        .addSubscription(
          name: 'Мой выбор',
          raw: _node,
          providerName: 'Provider',
        )
        .groupId;
    final restored = AppController.fromSnapshot(_snapshot(app));
    addTearDown(restored.dispose);
    restored.updateSubscription(
      groupId: id,
      raw: _node,
      providerName: 'Renamed',
    );
    expect(restored.groups.single.name, 'Мой выбор');
    expect(restored.groups.single.providerName, 'Renamed');
    expect(restored.groups.single.nameIsAutomatic, isFalse);
  });

  test('automatic provenance survives a cold restart', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app
        .addSubscription(raw: _node, providerName: 'Provider')
        .groupId;
    final snapshot = _snapshot(app);
    expect(snapshot['version'], 2);
    final restored = AppController.fromSnapshot(snapshot);
    addTearDown(restored.dispose);
    restored.updateSubscription(
      groupId: id,
      raw: _node,
      providerName: 'Renamed',
    );
    expect(restored.groups.single.name, 'Renamed');
  });

  test('legacy names remain manual without guessing their provenance', () {
    final app = AppController()
      ..addSubscription(name: 'Legacy choice', raw: _node);
    addTearDown(app.dispose);
    final snapshot = _snapshot(app)..['version'] = 1;
    (snapshot['groups'][0] as Map)
      ..remove('providerName')
      ..remove('nameIsAutomatic');
    final restored = AppController.fromSnapshot(snapshot);
    addTearDown(restored.dispose);
    restored.updateSubscription(
      groupId: restored.groups.single.id,
      raw: _node,
      providerName: 'Other',
    );
    expect(restored.groups.single.name, 'Legacy choice');
  });

  test(
    'partial replacement applies the matching title only after acceptance',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app.addSubscription(raw: _node, providerName: 'First').groupId;
      app.updateSubscription(
        groupId: id,
        raw: '$_node\nvless://invalid-uuid@sample.invalid:443?security=tls',
        providerName: 'Candidate',
      );
      expect(app.groups.single.name, 'First');
      final pending = app.pendingUpdate(id)!;
      expect(app.acceptPartialUpdate(pending), isTrue);
      expect(app.groups.single.name, 'Candidate');
    },
  );

  test('unsafe provider names never become a URL or credential display', () {
    final app = AppController();
    addTearDown(app.dispose);
    for (final name in [
      'https://sample.invalid/private-token',
      'vless://private',
      r'C:\private\token',
      '00000000-0000-4000-8000-000000000001',
      List.filled(64, 'a').join(),
    ]) {
      app.addSubscription(raw: _node, providerName: name);
      expect(app.groups.last.name, 'Подписка');
      expect(app.groups.last.providerName, isNull);
    }
    expect(safeSubscriptionName('\u202eNorth\n\u200bVPN\u0000'), 'North VPN');
    expect(
      safeSubscriptionName('Family VPN: Home / Travel'),
      'Family VPN: Home / Travel',
    );
    expect(
      safeSubscriptionName(List.filled(64, 'z').join()),
      List.filled(64, 'z').join(),
    );
    expect(
      safeSubscriptionName(
        'Key synthetic-private-token',
        sourceUrl: 'https://sample.invalid/sub/synthetic-private-token',
      ),
      isNull,
    );
    expect(
      safeSubscriptionName(List.filled(100, '🦊').join())!.runes.length,
      80,
    );
  });

  test('bad metadata types and unsanitized persisted title fail closed', () {
    final app = AppController()
      ..addSubscription(raw: _node, providerName: 'Valid');
    addTearDown(app.dispose);
    for (final value in [17, 'https://sample.invalid/private', '\u202eSpoof']) {
      final snapshot = _snapshot(app);
      snapshot['groups'][0]['providerName'] = value;
      expect(
        () => AppController.fromSnapshot(snapshot),
        throwsA(isA<SnapshotFormatException>()),
      );
    }
    final snapshot = _snapshot(app);
    snapshot['groups'][0]['nameIsAutomatic'] = 'true';
    expect(
      () => AppController.fromSnapshot(snapshot),
      throwsA(isA<SnapshotFormatException>()),
    );
  });
}
