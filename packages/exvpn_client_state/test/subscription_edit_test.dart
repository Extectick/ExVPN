import 'dart:convert';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const node =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Node';

void main() {
  test(
    'edits exactly one group, preserves profiles/selection, manual name survives snapshot and refresh',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final a = app
          .addSubscription(
            raw: node,
            providerName: 'Provider',
            sourceUrl: 'https://sample.invalid/old',
          )
          .groupId;
      app.addSubscription(name: 'Other', raw: node);
      final selected = app.selectedServerId;
      expect(
        app.editSubscription(
          groupId: a,
          name: 'My name',
          sourceUrl: 'https://sample.invalid/new',
        ),
        true,
      );
      expect(app.groups.first.sourceUrl, 'https://sample.invalid/new');
      expect(app.groups.first.updatedAt!.millisecondsSinceEpoch, 0);
      expect(app.groups.first.nameIsAutomatic, false);
      expect(app.groups.last.name, 'Other');
      expect(app.selectedServerId, selected);
      final restored = AppController.fromSnapshot(
        jsonDecode(jsonEncode(app.exportSnapshot())) as Map<String, dynamic>,
      );
      addTearDown(restored.dispose);
      restored.updateSubscription(
        groupId: a,
        raw: node,
        providerName: 'Changed',
      );
      expect(restored.groups.first.name, 'My name');
    },
  );

  test(
    'source edit invalidates an old partial confirmation; empty name restores provider naming',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app
          .addSubscription(raw: node, providerName: 'Provider')
          .groupId;
      app.updateSubscription(
        groupId: id,
        raw: '$node\nvless://bad@sample.invalid:443',
      );
      final candidate = app.pendingUpdate(id)!;
      final revision = app.groups.single.contentRevision;
      app.editSubscription(
        groupId: id,
        name: 'Manual',
        sourceUrl: 'https://sample.invalid/new',
      );
      expect(app.acceptPartialUpdate(candidate), false);
      expect(app.groups.single.contentRevision, revision + 1);
      app.editSubscription(groupId: id, name: '', sourceUrl: null);
      expect(app.groups.single.nameIsAutomatic, true);
      expect(app.groups.single.name, 'Provider');
      expect(app.groups.single.sourceUrl, isNull);
      expect(app.groups.single.servers.single.name, 'Node');
    },
  );

  test(
    'invalid metadata and a removed group never replace or resurrect data',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app.addSubscription(raw: node, name: 'Original').groupId;
      for (final source in [
        'http://sample.invalid/sub',
        'file:///private',
        'https://user@sample.invalid/sub',
      ]) {
        expect(
          () => app.editSubscription(
            groupId: id,
            name: 'Changed',
            sourceUrl: source,
          ),
          throwsA(isA<SnapshotFormatException>()),
        );
        expect(app.groups.single.name, 'Original');
      }
      expect(
        () => app.editSubscription(
          groupId: id,
          name: 'https://private.invalid/token',
        ),
        throwsFormatException,
      );
      app.removeSubscription(id);
      expect(app.editSubscription(groupId: id, name: 'Lost'), false);
      expect(app.groups, isEmpty);
    },
  );
}
