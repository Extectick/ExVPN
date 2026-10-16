import 'dart:convert';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const node =
    'vless://00000000-0000-4000-8000-000000000001@one.example.invalid:443?security=tls#One';
const source = 'https://provider.example.invalid/sub/synthetic-token';

Map<String, dynamic> copySnapshot(AppController controller) =>
    jsonDecode(jsonEncode(controller.exportSnapshot())) as Map<String, dynamic>;

void main() {
  test(
    'working profiles selection expansion source and date survive restart',
    () {
      final controller = AppController();
      final a = controller.addSubscription(
        name: 'A',
        raw: node,
        sourceUrl: source,
      );
      final b = controller.addSubscription(
        name: 'B',
        raw: node.replaceAll('One', 'Two'),
      );
      controller.selectServer(
        groupId: b.groupId,
        serverId: controller.groups.last.servers.first.id,
      );
      controller.toggleGroup(a.groupId);
      final restored = AppController.fromSnapshot(copySnapshot(controller));
      expect(restored.selectedGroupId, b.groupId);
      expect(restored.selectedServerId, controller.selectedServerId);
      expect(restored.groups.first.expanded, false);
      expect(restored.groups.first.sourceUrl, source);
      expect(
        restored.groups.first.updatedAt,
        controller.groups.first.updatedAt,
      );
      expect(
        restored.groups.first.servers.first.profile.toNativeJson(),
        controller.groups.first.servers.first.profile.toNativeJson(),
      );
      final next = restored.addSubscription(name: 'C', raw: node);
      expect(next.groupId, 'subscription-3');
    },
  );
  test('failed replacement preserves working source and update time', () {
    final controller = AppController();
    final result = controller.addSubscription(
      name: 'A',
      raw: node,
      sourceUrl: source,
    );
    final before = controller.groups.single.updatedAt;
    controller.updateSubscription(
      groupId: result.groupId,
      raw: 'broken',
      sourceUrl: 'https://other.invalid/new',
    );
    final restored = AppController.fromSnapshot(copySnapshot(controller));
    expect(restored.groups.single.sourceUrl, source);
    expect(restored.groups.single.updatedAt, before);
    expect(restored.groups.single.issues, isNotEmpty);
    expect(restored.selectedServer, isNotNull);
  });
  test('demo profiles never enter a persisted snapshot', () {
    final restored = AppController.fromSnapshot(
      copySnapshot(AppController.demo()),
    );
    expect(restored.groups, isEmpty);
    expect(restored.selectedServer, isNull);
  });
  test('manual replacement clears URL only after a valid applied update', () {
    final controller = AppController();
    final group = controller.addSubscription(
      name: 'A',
      raw: node,
      sourceUrl: source,
    );
    controller.updateSubscription(
      groupId: group.groupId,
      raw: 'broken',
      clearSourceUrl: true,
    );
    expect(controller.groups.single.sourceUrl, source);
    controller.updateSubscription(
      groupId: group.groupId,
      raw: node,
      clearSourceUrl: true,
    );
    expect(controller.groups.single.sourceUrl, isNull);
  });
  test('malformed types unknown schema and duplicate groups fail safely', () {
    final controller = AppController()..addSubscription(name: 'A', raw: node);
    for (final change in <void Function(Map<String, dynamic>)>[
      (m) => m['version'] = 1.0,
      (m) => m['inbounds'] = <dynamic>[],
      (m) => (m['groups'] as List).add(m['groups'][0]),
      (m) => m['groups'][0]['profiles'][0]['port'] = '443',
      (m) => m['groups'][0]['sourceUrl'] = 'http://unsafe.invalid',
      (m) => m['groups'][0]['profiles'][0]['tls']['enabled'] = 'true',
    ]) {
      final snapshot = copySnapshot(controller);
      change(snapshot);
      expect(
        () => AppController.fromSnapshot(snapshot),
        throwsA(isA<SnapshotFormatException>()),
      );
    }
    expect(controller.groups.single.servers, hasLength(1));
    expect(
      const SnapshotFormatException().toString(),
      isNot(contains('synthetic-token')),
    );
  });
  test('invalid source cannot partially add or replace state', () {
    final controller = AppController();
    expect(
      () => controller.addSubscription(
        name: 'A',
        raw: node,
        sourceUrl: 'https://user:secret@example.invalid',
      ),
      throwsA(isA<SnapshotFormatException>()),
    );
    expect(controller.groups, isEmpty);
  });
  test('missing selection falls back to a real remaining profile', () {
    final controller = AppController()..addSubscription(name: 'A', raw: node);
    final snapshot = copySnapshot(controller)..['selectedServerId'] = 'unknown';
    expect(
      AppController.fromSnapshot(snapshot).selectedServerId,
      controller.selectedServerId,
    );
  });
  test(
    'content revision tracks accepted replacements independently of UI and clock',
    () {
      final controller = AppController();
      final imported = controller.addSubscription(
        name: 'A',
        raw: node,
        sourceUrl: source,
      );
      final initial = controller.groups.single.contentRevision;
      controller.toggleGroup(imported.groupId);
      controller.selectServer(
        groupId: imported.groupId,
        serverId: controller.selectedServerId!,
      );
      expect(controller.groups.single.contentRevision, initial);
      controller.updateSubscription(groupId: imported.groupId, raw: node);
      expect(controller.groups.single.contentRevision, initial + 1);
      controller.updateSubscription(
        groupId: imported.groupId,
        raw: node,
        clearSourceUrl: true,
      );
      expect(controller.groups.single.contentRevision, initial + 2);
      controller.updateSubscription(groupId: imported.groupId, raw: 'broken');
      expect(controller.groups.single.contentRevision, initial + 2);
      final snapshot = copySnapshot(controller);
      expect(
        (snapshot['groups'][0] as Map).containsKey('contentRevision'),
        false,
      );
      expect(
        AppController.fromSnapshot(snapshot).groups.single.contentRevision,
        0,
      );
    },
  );
}
