// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/data_updates_platform_native.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge, off, running, profile;

class FakeUpdates implements DataUpdatesBackend {
  @override
  bool enabled = true;
  @override
  String? disabledReason;
  @override
  String channel = 'stable';
  DataUpdateSnapshot current = const DataUpdateSnapshot();
  Future<DataUpdateProposal>? stagedResult;
  Completer<void>? beforePublish;
  int staged = 0, applied = 0, cancelled = 0;
  bool pending = false;
  Object? stageError;
  Object? recoverError;
  Object? afterCommitError;
  @override
  Future<DataUpdateSnapshot> recover() async {
    if (recoverError != null) throw recoverError!;
    return current;
  }

  @override
  Future<DataUpdateProposal> stage() async {
    staged++;
    if (stageError != null) throw stageError!;
    final proposal =
        await (stagedResult ?? Future.value(const DataUpdateProposal(2, 1, 0)));
    pending = true;
    return proposal;
  }

  @override
  Future<DataUpdateSnapshot> apply(bool Function() canActivate) async {
    await beforePublish?.future;
    pending = false;
    if (!canActivate()) throw const DataUpdatesFailure('activationDeferred');
    applied++;
    current = const DataUpdateSnapshot(
      revision: 2,
      help: 'Проверенная новая справка.',
    );
    if (afterCommitError != null) throw afterCommitError!;
    return current;
  }

  @override
  Future<void> cancel() async {
    if (pending) {
      cancelled++;
      pending = false;
    }
  }
}

void main() {
  late FakeBridge bridge;
  late VpnController vpn;
  late FakeUpdates backend;
  late DataUpdatesController updates;
  setUp(() {
    bridge = FakeBridge();
    vpn = VpnController(bridge);
    backend = FakeUpdates();
    updates = DataUpdatesController(vpn: vpn, backend: backend);
  });
  tearDown(() async {
    updates.dispose();
    vpn.dispose();
    await bridge.close();
  });

  test('default delivery is disabled; malformed config never becomes a network client', () {
    expect(
      configuredDataUpdatesBackend(
        manifest: '',
        files: '',
        keyId: '',
        publicKey: '',
        channel: 'stable',
      ).enabled,
      false,
    );
    final invalid = configuredDataUpdatesBackend(
      manifest: 'http://updates.invalid/manifest',
      files: 'https://updates.invalid/files/',
      keyId: 'test',
      publicKey: base64.encode(List.filled(32, 1)),
      channel: 'stable',
    );
    expect(invalid.enabled, false);
    expect(invalid.disabledReason, 'invalid_configuration');
  });

  test('help accepts bounded plain text and rejects duplicate/unknown/control fields', () {
    final body = 'Выберите сервер.\nПопробуйте снова.';
    expect(
      parseConnectionHelp(
        Uint8List.fromList(
          utf8.encode(jsonEncode({'format': 1, 'body': body})),
        ),
      ),
      body,
    );
    expect(
      parseConnectionHelp(
        Uint8List.fromList(
          utf8.encode(jsonEncode({'body': body, 'format': 1})),
        ),
      ),
      body,
    );
    for (final value in [
      '{"format":1,"body":"one","body":"two"}',
      '{"format":1,"body":"text","url":"https://private.invalid"}',
      '{"format":1.0,"body":"text"}',
      jsonEncode({'format': 1, 'body': 'x' * 1501}),
      jsonEncode({'format': 1, 'body': 'hidden\u202econtent'}),
      jsonEncode({'format': 1, 'body': '  '}),
    ]) {
      expect(
        () => parseConnectionHelp(Uint8List.fromList(utf8.encode(value))),
        throwsA(isA<DataUpdatesFailure>()),
      );
    }
  });

  test(
    'recover and check never activate or disconnect an active VPN',
    () async {
      await vpn.initialize();
      bridge.emit(running());
      backend.current = const DataUpdateSnapshot(
        revision: 1,
        help: 'Сохранённая справка.',
      );
      await updates.initialize();
      await updates.check();
      expect(updates.snapshot.revision, 1);
      expect(updates.proposal!.revision, 2);
      expect(updates.canApply, false);
      await updates.apply();
      expect(updates.errorCode, 'update_requires_disconnected');
      expect(updates.proposal, isNotNull);
      expect(backend.applied, 0);
      expect(bridge.disconnects, 0);
      await updates.cancel();
      expect(updates.proposal, isNull);
      expect(updates.snapshot.revision, 1);
      expect(backend.cancelled, 1);
    },
  );

  test('unconfirmed native state cannot apply and failed checks keep previous help', () async {
    await updates.initialize();
    await updates.check();
    await updates.apply();
    expect(updates.errorCode, 'update_requires_disconnected');
    await updates.cancel();
    backend.stageError = StateError('private endpoint must never reach the UI');
    await updates.check();
    expect(updates.errorCode, 'operation_failed');
    expect(updates.snapshot.help, bundledConnectionHelp);
    expect(dataUpdatesErrorText(updates.errorCode), isNot(contains('private')));
  });

  test('staging suppresses duplicate commands and closing controller cancels late stage', () async {
    final completed = Completer<DataUpdateProposal>();
    backend.stagedResult = completed.future;
    final check = updates.check();
    await updates.check();
    await updates.cancel();
    expect(backend.staged, 1);
    updates.dispose();
    // Replace the disposed instance so tearDown does not dispose it twice.
    updates = DataUpdatesController(
      vpn: null,
      backend: DisabledDataUpdatesBackend(),
    );
    completed.complete(const DataUpdateProposal(2, 1, 0));
    await check;
    expect(backend.pending, false);
    expect(backend.cancelled, 1);
    expect(backend.applied, 0);
  });

  test(
    'apply reserves connect/policy and updates text only after commit',
    () async {
      await vpn.initialize();
      await updates.initialize();
      await updates.check();
      backend.beforePublish = Completer<void>();
      final applying = updates.apply();
      await Future<void>.delayed(Duration.zero);
      expect(vpn.commandPending, true);
      await vpn.connect(profile);
      await expectLater(vpn.setExclusions({}), throwsA(isA<Exception>()));
      expect(bridge.connects, 0);
      expect(updates.snapshot.revision, isNull);
      backend.beforePublish!.complete();
      await applying;
      expect(updates.snapshot.revision, 2);
      expect(updates.snapshot.help, 'Проверенная новая справка.');
      expect(vpn.commandPending, false);
      expect(bridge.disconnects, 0);
      expect(updates.proposal, isNull);
    },
  );

  test('native start then stop during apply invalidates commit even after returning off', () async {
    await vpn.initialize();
    await updates.initialize();
    await updates.check();
    backend.beforePublish = Completer<void>();
    final applying = updates.apply();
    await Future<void>.delayed(Duration.zero);
    bridge.emit(running());
    bridge.emit(off);
    backend.beforePublish!.complete();
    await applying;
    expect(updates.errorCode, 'activationDeferred');
    expect(updates.snapshot.revision, isNull);
    expect(backend.applied, 0);
    expect(vpn.commandPending, false);
    expect(updates.proposal, isNull);
  });

  test(
    'fresh native status blocks apply despite an old disconnected display',
    () async {
      await vpn.initialize();
      await updates.check();
      bridge.current =
          running(); // No stream event, authoritative refresh still wins.
      await updates.apply();
      expect(updates.errorCode, 'update_requires_disconnected');
      expect(updates.proposal, isNotNull);
      expect(backend.applied, 0);
      expect(vpn.commandPending, false);
    },
  );

  test(
    'pending VPN command prevents apply without consuming the stage',
    () async {
      await vpn.initialize();
      await updates.check();
      final pending = Completer<void>();
      bridge.connectResult = pending.future;
      final connecting = vpn.connect(profile);
      await updates.apply();
      expect(updates.proposal, isNotNull);
      expect(backend.applied, 0);
      expect(updates.errorCode, 'update_requires_disconnected');
      pending.complete();
      await connecting;
    },
  );

  test(
    'stale revision response reconciles data committed by another process',
    () async {
      backend.current = const DataUpdateSnapshot(
        revision: 1,
        help: 'Old working help',
      );
      await updates.initialize();
      backend.current = const DataUpdateSnapshot(
        revision: 3,
        help: 'Other process committed help',
      );
      backend.stageError = const DataUpdatesFailure('staleRevision');
      await updates.check();
      expect(updates.snapshot.revision, 3);
      expect(updates.snapshot.help, 'Other process committed help');
      expect(updates.notice, 'Новой подписанной ревизии нет.');
      expect(updates.errorCode, isNull);
    },
  );

  test('post-commit read failure reconciles accepted revision and keeps safe error visible', () async {
    await vpn.initialize();
    backend.current = const DataUpdateSnapshot(
      revision: 1,
      help: 'Old working help',
    );
    await updates.initialize();
    await updates.check();
    backend.afterCommitError = const DataUpdatesFailure('storageFailure');
    await updates.apply();
    expect(updates.snapshot.revision, 2);
    expect(updates.snapshot.help, 'Проверенная новая справка.');
    expect(updates.errorCode, 'storageFailure');
    expect(updates.notice, 'Сохранённые данные повторно проверены.');
    expect(updates.proposal, isNull);
  });

  test('failed reconciliation preserves working help; explicit reread later recovers', () async {
    await vpn.initialize();
    backend.current = const DataUpdateSnapshot(
      revision: 1,
      help: 'Old working help',
    );
    await updates.initialize();
    await updates.check();
    backend.afterCommitError = const DataUpdatesFailure('storageFailure');
    backend.recoverError = const DataUpdatesFailure('storageFailure');
    await updates.apply();
    expect(updates.snapshot.revision, 1);
    expect(updates.snapshot.help, 'Old working help');
    expect(updates.errorCode, 'storageFailure');
    backend.recoverError = null;
    await updates.recover();
    expect(updates.snapshot.revision, 2);
    expect(updates.errorCode, isNull);
  });
}
