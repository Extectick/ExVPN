// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/client_logs.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/safe_diagnostics.dart';
import 'package:exvpn/services/subscription_persistence.dart';
import 'package:exvpn/services/subscription_store.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

const secret = 'PRIVATE-SYNTHETIC-token-and-name';
const profile =
    'vless://00000000-0000-4000-8000-000000000001@private.invalid:443?security=tls#PRIVATE-SYNTHETIC-token-and-name';
String diagnostics() => safeDiagnostics(
  status: const VpnStatus(
    phase: VpnPhase.disconnected,
    processCrashProtection: false,
  ),
  platform: 'windows',
  secureStorageAvailable: true,
  coreVersion: '26.10.10',
);

class _Bridge implements VpnBridge {
  final states = StreamController<VpnStatus>.broadcast(sync: true);
  final statistics = StreamController<TrafficStats>.broadcast(sync: true);
  VpnStatus current = const VpnStatus(
    phase: VpnPhase.disconnected,
    processCrashProtection: false,
  );
  void emit(VpnStatus value) {
    current = value;
    states.add(value);
  }

  Future<void> close() async {
    await states.close();
    await statistics.close();
  }

  @override
  Stream<VpnStatus> get statuses => states.stream;
  @override
  Stream<TrafficStats> get traffic => statistics.stream;
  @override
  Future<VpnStatus> getStatus() async => current;
  @override
  Future<void> connect(ConnectionProfile profile) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<List<ApplicationIdentity>> listApplications() async => [];
  @override
  Future<void> setExclusions(Set<String> applicationIds) async {}
  @override
  Future<Set<String>> getExclusions() async => {};
  @override
  Future<ProbeResult> probe(ConnectionProfile profile) async =>
      const ProbeResult(reachable: false);
  @override
  Future<String> coreVersion() async => secret;
  @override
  Future<void> openSystemProtectionSettings() async {}
}

class _AppUpdates extends AppUpdatesController {
  _AppUpdates() : super(fullBackend: const DisabledFullUpdatesBackend());
  AppUpdateState value = const AppUpdateState();
  @override
  AppUpdateState get state => value;
  void emit(AppUpdateState next) {
    value = next;
    notifyListeners();
  }
}

class _ProtectionBridge extends _Bridge implements ConnectionProtectionBridge {
  bool enabled = false;
  @override
  Future<ConnectionProtection> getConnectionProtection() async =>
      ConnectionProtection(
        supported: true,
        enabled: enabled,
        active: false,
        systemManaged: false,
      );
  @override
  Future<ConnectionProtection> setConnectionProtection(bool value) async {
    enabled = value;
    return getConnectionProtection();
  }
}

class _PatchBackend implements DartUpdatesBackend {
  @override
  String get track => secret;
  @override
  String? get disabledReason => secret;
  @override
  Future<DartPatchSnapshot> read() async =>
      const DartPatchSnapshot(available: true, current: 1, next: 2);
  @override
  Future<DartUpdateCheck> check() async =>
      DartUpdateCheck(DartUpdateStatus.outdated, await read());
  @override
  Future<DartPatchSnapshot> download() async => throw StateError(secret);
}

class _FailingStore implements SecureKeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('https://private.invalid/$secret');
  @override
  Future<void> delete(String key) async {}
}

void main() {
  test(
    'schema2 preserves valid schema1 and discards secret-bearing extras',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      app.addSubscription(
        name: secret,
        providerName: secret,
        raw: profile,
        sourceUrl: 'https://private.invalid/sub/$secret',
      );
      final updates = _AppUpdates();
      addTearDown(updates.dispose);
      final logs = ClientLogs(controller: app, appUpdates: updates);
      addTearDown(logs.dispose);
      final valid = diagnostics();
      final report = jsonDecode(logs.buildReport(valid)) as Map;
      expect(report['schema'], 2);
      expect(report['diagnostics'], jsonDecode(valid));
      updates.emit(
        const AppUpdateState(
          phase: AppUpdateStatePhase.failed,
          availableVersion: secret,
          errorCode: secret,
        ),
      );
      final tainted = jsonDecode(valid) as Map<String, dynamic>;
      tainted['profileName'] = secret;
      tainted['coreVersion'] = '$secret\n';
      tainted['errorCode'] = secret;
      tainted['version'] = secret;
      (tainted['updates'] as Map)['privateUrl'] = secret;
      final exported = logs.buildReport(jsonEncode(tainted));
      for (final forbidden in [
        secret,
        'private.invalid',
        '00000000-0000-',
        'sourceUrl',
        'profileName',
        'privateUrl',
      ]) {
        expect(exported, isNot(contains(forbidden)));
      }
      expect(exported, contains('operation_failed'));
      expect(exported, contains('vless'));
    },
  );

  test(
    'traffic, presentation and profile identity changes are deduplicated',
    () async {
      final bridge = _Bridge();
      addTearDown(bridge.close);
      final vpn = VpnController(bridge);
      addTearDown(vpn.dispose);
      await vpn.initialize();
      final app = AppController.demo();
      addTearDown(app.dispose);
      final logs = ClientLogs(controller: app, vpn: vpn);
      addTearDown(logs.dispose);
      bridge.emit(
        const VpnStatus(
          phase: VpnPhase.connected,
          processCrashProtection: false,
          activeProfileId: secret,
        ),
      );
      final count = logs.eventCount;
      for (var i = 0; i < 100; i++) {
        bridge.statistics.add(
          TrafficStats(uploadBytes: i, downloadBytes: i * 3),
        );
        app.toggleGroup(app.groups.first.id);
      }
      bridge.emit(
        const VpnStatus(
          phase: VpnPhase.connected,
          processCrashProtection: false,
          activeProfileId: 'another-private-id',
        ),
      );
      expect(logs.eventCount, count);
      bridge.emit(
        const VpnStatus(
          phase: VpnPhase.blocked,
          processCrashProtection: true,
          errorCode: 'tunnel_https_failed',
        ),
      );
      expect(logs.eventCount, count + 1);
      expect(logs.buildReport(diagnostics()), isNot(contains(secret)));
    },
  );

  testWidgets(
    'ring evicts old events and periodic cleanup expires all at 30 minutes',
    (tester) async {
      var now = DateTime.utc(2026);
      final app = AppController();
      addTearDown(app.dispose);
      final updates = _AppUpdates();
      addTearDown(updates.dispose);
      final logs = ClientLogs(
        controller: app,
        appUpdates: updates,
        now: () => now,
      );
      for (var i = 0; i < 100; i++) {
        now = now.add(const Duration(seconds: 1));
        updates.emit(
          AppUpdateState(
            phase: i.isEven
                ? AppUpdateStatePhase.checking
                : AppUpdateStatePhase.hidden,
          ),
        );
      }
      expect(logs.eventCount, ClientLogs.maxEvents);
      final report = logs.buildReport(diagnostics());
      expect(
        utf8.encode(report).length,
        lessThanOrEqualTo(ClientLogs.maxReportBytes),
      );
      final events = (jsonDecode(report) as Map)['events'] as List;
      expect((events.first as Map)['elapsedMs'], greaterThan(0));
      var changes = 0;
      logs.addListener(() => changes++);
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 1));
      expect(changes, 1);
      expect(logs.eventCount, 0);
      expect(
        (jsonDecode(logs.buildReport(diagnostics())) as Map)['events'],
        isEmpty,
      );
      logs.dispose();
    },
  );

  test(
    'clear remains empty on duplicate state and disposal detaches producers',
    () {
      final app = AppController();
      addTearDown(app.dispose);
      final updates = _AppUpdates();
      addTearDown(updates.dispose);
      final logs = ClientLogs(controller: app, appUpdates: updates);
      logs.clear();
      updates.emit(const AppUpdateState());
      expect(logs.eventCount, 0);
      updates.emit(const AppUpdateState(phase: AppUpdateStatePhase.checking));
      expect(logs.eventCount, 1);
      logs.dispose();
      updates.emit(const AppUpdateState(phase: AppUpdateStatePhase.failed));
      expect(logs.eventCount, 0);
      expect(
        () => logs.buildReport(diagnostics()),
        throwsA(isA<ClientLogsReportFailure>()),
      );
    },
  );

  test('malformed or oversized snapshots fail without retaining raw input', () {
    final app = AppController();
    addTearDown(app.dispose);
    final logs = ClientLogs(controller: app);
    addTearDown(logs.dispose);
    final count = logs.eventCount;
    for (final value in [secret, '[]', '{"schema":99}', secret * 4000]) {
      expect(
        () => logs.buildReport(value),
        throwsA(isA<ClientLogsReportFailure>()),
      );
    }
    expect(logs.eventCount, count);
    expect(logs.buildReport(diagnostics()), isNot(contains(secret)));
  });

  test('storage failures record only the typed retryable code', () async {
    final app = AppController();
    addTearDown(app.dispose);
    final persistence = SubscriptionPersistence(
      app,
      SubscriptionStore.forTesting(_FailingStore()),
    );
    addTearDown(persistence.dispose);
    final logs = ClientLogs(controller: app, persistence: persistence);
    addTearDown(logs.dispose);
    app.addSubscription(name: secret, raw: profile);
    await persistence.flush();
    final report = logs.buildReport(diagnostics());
    expect(report, contains('writeFailed'));
    expect(report, isNot(contains(secret)));
    expect(report, isNot(contains('private.invalid')));
  });

  test(
    'protection preference and confirmed active state stay distinct',
    () async {
      final bridge = _ProtectionBridge();
      addTearDown(bridge.close);
      final vpn = VpnController(bridge);
      addTearDown(vpn.dispose);
      final app = AppController();
      addTearDown(app.dispose);
      final logs = ClientLogs(controller: app, vpn: vpn);
      addTearDown(logs.dispose);
      await vpn.refreshConnectionProtection();
      expect(await vpn.setConnectionProtection(true), isTrue);
      final events =
          (jsonDecode(logs.buildReport(diagnostics())) as Map)['events']
              as List;
      final state = (events.last as Map)['state'] as Map;
      expect(state['protectionSupported'], isTrue);
      expect(state['protectionEnabled'], isTrue);
      expect(state['protectionActive'], isFalse);
      expect(state['protectionSystemManaged'], isFalse);
      expect(state['protectionBusy'], isFalse);
    },
  );

  test('Dart updates retain patch numbers and typed errors but no backend strings', () async {
    final app = AppController();
    addTearDown(app.dispose);
    final updates = DartUpdatesController(backend: _PatchBackend());
    addTearDown(updates.dispose);
    final logs = ClientLogs(controller: app, dartUpdates: updates);
    addTearDown(logs.dispose);
    await updates.initialize();
    await updates.check();
    // A scheduled restart has priority, so use a confirmed same-patch read
    // directly for a download-error producer without exposing backend details.
    updates.snapshot = const DartPatchSnapshot(
      available: true,
      current: 1,
      next: 1,
    );
    await updates.download();
    final report = logs.buildReport(diagnostics());
    expect(report, isNot(contains(secret)));
    expect(report, contains('operationFailed'));
    expect(report, contains('"current": 1'));
    expect(report, contains('"next": 2'));
  });
}
