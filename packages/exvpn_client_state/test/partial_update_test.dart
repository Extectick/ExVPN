import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const oldProfile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Old';
const newProfile =
    'vless://00000000-0000-4000-8000-000000000002@sample.invalid:443?security=tls#New';
const sharedProfile =
    'vless://00000000-0000-4000-8000-000000000003@sample.invalid:443?security=tls#Shared';
const broken = 'unknown://PRIVATE-CREDENTIAL@sample.invalid/PRIVATE-TOKEN';

void main() {
  late AppController app;
  late String id;
  setUp(() {
    app = AppController();
    id = app
        .addSubscription(
          name: 'Example',
          raw: oldProfile,
          sourceUrl: 'https://example.invalid/old-source',
        )
        .groupId;
  });
  tearDown(() => app.dispose());

  test('partial update keeps the working data until exact acceptance', () {
    final before = app.groups.single;
    final result = app.updateSubscription(
      groupId: id,
      raw: '$newProfile\n$broken',
      sourceUrl: 'https://example.invalid/new-source',
    );
    expect(result.applied, isFalse);
    expect(app.selectedServer!.name, 'Old');
    expect(app.groups.single.sourceUrl, before.sourceUrl);
    expect(app.groups.single.updatedAt, before.updatedAt);
    expect(app.groups.single.contentRevision, before.contentRevision);
    final candidate = app.pendingUpdate(id)!;
    expect(candidate.previousCount, 1);
    expect(candidate.supportedCount, 1);
    expect(candidate.issues.single.index, 2);
    expect(candidate.toString(), 'PendingSubscriptionUpdate(<redacted>)');
    expect(app.acceptPartialUpdate(candidate), isTrue);
    expect(app.selectedServer!.name, 'New');
    expect(app.groups.single.sourceUrl, 'https://example.invalid/new-source');
    expect(app.groups.single.contentRevision, before.contentRevision + 1);
    expect(app.groups.single.issues.single.index, 2);
    expect(app.pendingUpdate(id), isNull);
    expect(app.acceptPartialUpdate(candidate), isFalse);
  });

  test('manual replacement removes source only after acceptance', () {
    app.updateSubscription(
      groupId: id,
      raw: '$newProfile\n$broken',
      clearSourceUrl: true,
    );
    expect(app.groups.single.sourceUrl, isNotNull);
    expect(app.acceptPartialUpdate(app.pendingUpdate(id)!), isTrue);
    expect(app.groups.single.sourceUrl, isNull);
  });

  for (final (label, newer) in [
    ('valid', newProfile),
    ('invalid', broken),
    ('partial', '$sharedProfile\n$broken'),
  ]) {
    test(
      'superseding $label replacement invalidates previous confirmation',
      () {
        app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
        final stale = app.pendingUpdate(id)!;
        app.updateSubscription(groupId: id, raw: newer);
        final before = app.exportSnapshot();
        expect(app.acceptPartialUpdate(stale), isFalse);
        expect(app.exportSnapshot(), before);
      },
    );
  }

  test('a candidate cannot cross controller or group ownership', () {
    app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    final candidate = app.pendingUpdate(id)!;
    final other = AppController()
      ..addSubscription(name: 'Other', raw: oldProfile);
    addTearDown(other.dispose);
    other.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    expect(other.acceptPartialUpdate(candidate), isFalse);
    expect(other.selectedServer!.name, 'Old');
    app.removeSubscription(id);
    expect(app.pendingUpdate(id), isNull);
    expect(app.acceptPartialUpdate(candidate), isFalse);
  });

  test('pending secret data is not persisted or restored as accepted', () {
    app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    final snapshot = app.exportSnapshot();
    final restored = AppController.fromSnapshot(
      Map<String, dynamic>.from(snapshot),
    );
    addTearDown(restored.dispose);
    expect(restored.selectedServer!.name, 'Old');
    expect(restored.pendingUpdate(id), isNull);
    expect(restored.groups.single.issues.single.index, 2);
    expect(snapshot.toString(), isNot(contains('PRIVATE-')));
  });

  test('accepted partial replacement survives snapshot round trip', () {
    app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    app.acceptPartialUpdate(app.pendingUpdate(id)!);
    final restored = AppController.fromSnapshot(
      Map<String, dynamic>.from(app.exportSnapshot()),
    );
    addTearDown(restored.dispose);
    expect(restored.selectedServer!.name, 'New');
    expect(restored.groups.single.issues.single.index, 2);
  });

  test(
    'selection and expansion survive if the selected profile still exists',
    () {
      app.updateSubscription(groupId: id, raw: '$oldProfile\n$sharedProfile');
      final selected = app.groups.single.servers.last.id;
      app.selectServer(groupId: id, serverId: selected);
      app.updateSubscription(
        groupId: id,
        raw: '$sharedProfile\n$newProfile\n$broken',
      );
      final candidate = app.pendingUpdate(id)!;
      app.toggleGroup(id);
      expect(app.acceptPartialUpdate(candidate), isTrue);
      expect(app.selectedServerId, selected);
      expect(app.groups.single.expanded, isFalse);
    },
  );

  test('zero supported records cannot offer an empty replacement', () {
    app.updateSubscription(groupId: id, raw: broken);
    expect(app.pendingUpdate(id), isNull);
    expect(app.selectedServer!.name, 'Old');
  });

  test('new partial imports expose issues without a replacement candidate', () {
    final created = app.addSubscription(
      name: 'Second',
      raw: '$newProfile\n$broken',
    );
    expect(created.applied, isTrue);
    expect(created.issues.single.index, 2);
    expect(app.pendingUpdate(created.groupId), isNull);
  });
}
