import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const _uuid = '00000000-0000-4000-8000-000000000001';
String _node(String host, String name) =>
    'vless://$_uuid@$host.invalid:443?security=tls#${Uri.encodeComponent(name)}';

void main() {
  group('session flow', () {
    late AppController controller;

    setUp(() => controller = AppController());
    tearDown(() => controller.dispose());

    test('normal startup has no demo servers and offers the empty CTA', () {
      expect(controller.groups, isEmpty);
      expect(controller.selectedServer, isNull);
      expect(controller.isDemo, isFalse);
      expect(controller.showAddSubscriptionButton, isTrue);
    });

    test(
      'subscriptions can collapse without losing the selected connection',
      () {
        final imported = controller.addSubscription(
          name: 'Main',
          raw: '${_node('first', 'First')}\n${_node('second', 'Second')}',
        );
        final second = controller.groups.single.servers[1];
        expect(
          controller.selectServer(
            groupId: imported.groupId,
            serverId: second.id,
          ),
          isTrue,
        );
        expect(controller.toggleGroup(imported.groupId), isTrue);
        expect(controller.groups.single.expanded, isFalse);
        expect(controller.selectedServer, same(second));
        expect(controller.showAddSubscriptionButton, isFalse);
        expect(controller.selectedServer!.latencyMs, isNull);
      },
    );

    test(
      'removing selected group falls back to a remaining nonempty group',
      () {
        final first = controller.addSubscription(
          name: 'One',
          raw: _node('a', 'A'),
        );
        final second = controller.addSubscription(
          name: 'Two',
          raw: _node('b', 'B'),
        );
        expect(controller.selectedGroupId, first.groupId);
        expect(controller.removeSubscription(first.groupId), isTrue);
        expect(controller.selectedGroupId, second.groupId);
        expect(controller.selectedServer!.name, 'B');
        controller.removeSubscription(second.groupId);
        expect(controller.selectedServer, isNull);
        expect(controller.showAddSubscriptionButton, isTrue);
      },
    );

    test(
      'removing another group preserves the selected group and connection',
      () {
        final first = controller.addSubscription(
          name: 'One',
          raw: _node('a', 'A'),
        );
        final second = controller.addSubscription(
          name: 'Two',
          raw: _node('b', 'B'),
        );
        controller.selectServer(
          groupId: second.groupId,
          serverId: controller.groups.last.servers.single.id,
        );
        final selected = controller.selectedServer;
        controller.removeSubscription(first.groupId);
        expect(controller.selectedServer, same(selected));
      },
    );

    test(
      'identical profiles in different subscriptions have separate selection',
      () {
        final first = controller.addSubscription(
          name: 'One',
          raw: _node('a', 'A'),
        );
        final second = controller.addSubscription(
          name: 'Two',
          raw: _node('a', 'A'),
        );
        final id = controller.groups.first.servers.single.id;
        expect(
          controller.selectServer(groupId: second.groupId, serverId: id),
          isTrue,
        );
        controller.removeSubscription(first.groupId);
        expect(controller.selectedGroupId, second.groupId);
        expect(controller.selectedServerId, id);
      },
    );

    test('invalid replacement preserves the last good nodes and selection', () {
      final imported = controller.addSubscription(
        name: 'One',
        raw: _node('a', 'A'),
      );
      final before = controller.selectedServer;
      final replacement = controller.updateSubscription(
        groupId: imported.groupId,
        raw: 'unknown://secret@example.invalid:443/secret-token',
      );
      expect(replacement.applied, isFalse);
      expect(replacement.issues, isNotEmpty);
      expect(controller.selectedServer, same(before));
      expect(controller.groups.single.issues, isNotEmpty);
      expect(replacement.issues.toString(), isNot(contains('secret')));
    });

    test('unsupported records are skipped when replacing working nodes', () {
      final imported = controller.addSubscription(
        name: 'One',
        raw: '${_node('a', 'A')}\n${_node('b', 'B')}',
      );
      final replacement = controller.updateSubscription(
        groupId: imported.groupId,
        raw: '${_node('c', 'C')}\nunsupported://test.invalid',
      );
      expect(replacement.applied, isTrue);
      expect(controller.groups.single.servers.map((entry) => entry.name), [
        'C',
      ]);
      expect(
        controller.groups.single.issues.single.code,
        ImportIssueCode.unsupportedProtocol,
      );
      expect(controller.pendingUpdate(imported.groupId), isNull);
    });

    test('successful replacement retains a still-existing selected ID', () {
      final a = _node('a', 'A');
      final b = _node('b', 'B');
      final imported = controller.addSubscription(name: 'One', raw: '$a\n$b');
      final selectedId = controller.groups.single.servers.last.id;
      controller.selectServer(groupId: imported.groupId, serverId: selectedId);
      controller.toggleGroup(imported.groupId);
      final replacement = controller.updateSubscription(
        groupId: imported.groupId,
        raw: '$b\n${_node('c', 'C')}',
      );
      expect(replacement.applied, isTrue);
      expect(controller.selectedServerId, selectedId);
      expect(controller.groups.single.expanded, isFalse);
      expect(controller.groups.single.issues, isEmpty);
    });

    test('removed selected node falls back within its replacement group', () {
      controller.addSubscription(name: 'Earlier', raw: _node('a', 'A'));
      final later = controller.addSubscription(
        name: 'Later',
        raw: _node('b', 'B'),
      );
      controller.selectServer(
        groupId: later.groupId,
        serverId: controller.groups.last.servers.single.id,
      );
      controller.updateSubscription(
        groupId: later.groupId,
        raw: _node('c', 'C'),
      );
      expect(controller.selectedGroupId, later.groupId);
      expect(controller.selectedServer!.name, 'C');
    });

    test('failed new import remains an error group without the empty CTA', () {
      final result = controller.addSubscription(name: 'Broken', raw: '');
      expect(result.applied, isFalse);
      expect(controller.groups.single.name, 'Broken');
      expect(controller.groups.single.servers, isEmpty);
      expect(
        controller.groups.single.issues.single.code,
        ImportIssueCode.empty,
      );
      expect(controller.showAddSubscriptionButton, isFalse);
      expect(controller.selectedServer, isNull);
      controller.updateSubscription(
        groupId: result.groupId,
        raw: _node('a', 'A'),
      );
      expect(controller.groups.single.issues, isEmpty);
      expect(controller.selectedServer!.name, 'A');
    });

    test(
      'partial new import retains valid records and rejected-record notices',
      () {
        final result = controller.addSubscription(
          name: 'Partial',
          raw: '${_node('a', 'A')}\nunsupported://test.invalid',
        );
        expect(result.applied, isTrue);
        expect(controller.groups.single.servers, hasLength(1));
        expect(controller.groups.single.issues, hasLength(1));
      },
    );

    test('invalid selection cannot mutate an existing choice', () {
      final group = controller.addSubscription(
        name: 'One',
        raw: _node('a', 'A'),
      );
      final before = controller.selectedServer;
      expect(
        controller.selectServer(groupId: group.groupId, serverId: 'missing'),
        isFalse,
      );
      expect(
        controller.selectServer(groupId: 'missing', serverId: before!.id),
        isFalse,
      );
      expect(controller.selectedServer, same(before));
      expect(controller.toggleGroup('missing'), isFalse);
      expect(controller.removeSubscription('missing'), isFalse);
    });

    test('read-only state prevents mutation outside controller', () {
      controller.addSubscription(name: 'One', raw: _node('a', 'A'));
      expect(() => controller.groups.clear(), throwsUnsupportedError);
      expect(
        () => controller.groups.single.servers.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => controller.groups.single.issues.clear(),
        throwsUnsupportedError,
      );
    });

    test(
      'listeners observe committed state and removed groups cannot update',
      () async {
        final seen = <int>[];
        final done = Completer<void>();
        controller.changes.listen(
          (_) => seen.add(controller.groups.length),
          onDone: done.complete,
        );
        final result = controller.addSubscription(
          name: 'One',
          raw: _node('a', 'A'),
        );
        controller.removeSubscription(result.groupId);
        expect(seen, [1, 0]);
        expect(
          () => controller.updateSubscription(groupId: result.groupId, raw: ''),
          throwsStateError,
        );
        controller.dispose();
        await done.future;
        expect(controller.groups, isEmpty);
        expect(
          () => controller.addSubscription(name: '', raw: ''),
          throwsStateError,
        );
      },
    );
  });

  group('demo and presentation metadata', () {
    test(
      'demo fixture is explicit, invalid-address-only, and never a connection',
      () {
        final controller = AppController.demo();
        addTearDown(controller.dispose);
        expect(controller.isDemo, isTrue);
        expect(controller.groups.map((group) => group.servers.length), [4, 2]);
        expect(controller.groups.map((group) => group.expanded), [true, false]);
        expect(controller.selectedServer!.name, 'Амстердам');
        for (final server in controller.groups.expand(
          (group) => group.servers,
        )) {
          expect(server.isDemo, isTrue);
          expect(server.latencyMs, isNotNull);
          expect(server.profile.server, endsWith('.invalid'));
          expect(server.profile.uuid, isNull);
          expect(server.profile.password, isNull);
        }
        expect(controller.selectedServer!.protocolLabel, 'VLESS · Reality');
        expect(
          controller.groups.first.servers[1].protocolLabel,
          'VLESS · XHTTP',
        );
        expect(controller.groups.first.servers[2].protocolLabel, 'Hysteria2');
        expect(
          controller.groups.first.servers[3].protocolLabel,
          'Trojan · TLS',
        );
      },
    );

    test(
      'explicit flags become country metadata without hostname guessing',
      () {
        final parser = SubscriptionParser();
        final flagged = parser
            .parse(_node('a', '🇳🇱 Amsterdam'))
            .profiles
            .single;
        final entry = ServerEntry(profile: flagged);
        expect(entry.countryCode, 'NL');
        expect(entry.name, 'Amsterdam');
        final plain = parser.parse(_node('b', 'Amsterdam')).profiles.single;
        expect(ServerEntry(profile: plain).countryCode, isNull);
        expect(
          () => ServerEntry(profile: plain, latencyMs: 42),
          throwsArgumentError,
        );
        expect(entry.toString(), isNot(contains('Amsterdam')));
        expect(entry.toString(), isNot(contains('.invalid')));
      },
    );

    test(
      'replacing a demo group removes its synthetic latency and demo status',
      () {
        final controller = AppController.demo();
        addTearDown(controller.dispose);
        controller.removeSubscription('demo-backup');
        controller.updateSubscription(
          groupId: 'demo-main',
          raw: _node('a', 'A'),
        );
        expect(controller.isDemo, isFalse);
        expect(controller.selectedServer!.isDemo, isFalse);
        expect(controller.selectedServer!.latencyMs, isNull);
      },
    );
  });
}
