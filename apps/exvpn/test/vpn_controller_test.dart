import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

final profile = const SubscriptionParser()
    .parse(
      'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
    )
    .profiles
    .single;
const off = VpnStatus(
  phase: VpnPhase.disconnected,
  processCrashProtection: false,
);
VpnStatus running() => VpnStatus(
  phase: VpnPhase.connected,
  processCrashProtection: false,
  activeProfileId: profile.id,
  connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
);

class FakeBridge implements VpnBridge {
  final states = StreamController<VpnStatus>.broadcast(sync: true);
  final statistics = StreamController<TrafficStats>.broadcast(sync: true);
  VpnStatus current = off;
  Future<VpnStatus>? snapshot;
  Future<void>? connectResult;
  Future<void>? policyWrite;
  Future<Set<String>>? policyRead;
  int connects = 0;
  int disconnects = 0;
  Set<String> excluded = {};
  void emit(VpnStatus value) {
    current = value;
    states.add(value);
  }

  @override
  Stream<VpnStatus> get statuses => states.stream;
  @override
  Stream<TrafficStats> get traffic => statistics.stream;
  @override
  Future<VpnStatus> getStatus() => snapshot ?? Future.value(current);
  @override
  Future<void> connect(ConnectionProfile value) async {
    connects++;
    await (connectResult ?? Future.value());
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    emit(off);
  }

  @override
  Future<String> coreVersion() async => '26.10.10';
  @override
  Future<Set<String>> getExclusions() => policyRead ?? Future.value(excluded);
  @override
  Future<void> setExclusions(Set<String> ids) async {
    await (policyWrite ?? Future.value());
    excluded = ids;
  }

  @override
  Future<List<ApplicationIdentity>> listApplications() async => [];
  @override
  Future<void> openSystemProtectionSettings() async {}
  @override
  Future<ProbeResult> probe(ConnectionProfile value) async =>
      const ProbeResult(reachable: false);
  Future<void> close() async {
    await states.close();
    await statistics.close();
  }
}

void main() {
  late FakeBridge bridge;
  late VpnController vpn;
  setUp(() {
    bridge = FakeBridge();
    vpn = VpnController(bridge);
  });
  tearDown(() async {
    vpn.dispose();
    await bridge.close();
  });

  test(
    'command acceptance never invents connected or crash protection',
    () async {
      await vpn.initialize();
      await vpn.connect(profile);
      expect(bridge.connects, 1);
      expect(vpn.status.phase, VpnPhase.disconnected);
      expect(vpn.status.processCrashProtection, false);
      bridge.emit(running());
      expect(vpn.status.phase, VpnPhase.connected);
      expect(vpn.status.processCrashProtection, false);
    },
  );

  test('an old snapshot cannot overwrite a newer event', () async {
    final response = Completer<VpnStatus>();
    bridge.snapshot = response.future;
    final started = vpn.initialize();
    bridge.emit(running());
    response.complete(off);
    await started;
    expect(vpn.status.phase, VpnPhase.connected);
  });

  test(
    'explicit disconnect cancels pending permission and ignores late failure',
    () async {
      await vpn.initialize();
      final permission = Completer<void>();
      bridge.connectResult = permission.future;
      final pending = vpn.connect(profile);
      bridge.emit(
        VpnStatus(
          phase: VpnPhase.requestingPermission,
          processCrashProtection: false,
          activeProfileId: profile.id,
        ),
      );
      await vpn.disconnect();
      permission.completeError(const VpnFailure('permission_cancelled'));
      await pending;
      expect(vpn.status.phase, VpnPhase.disconnected);
      expect(vpn.lastErrorCode, isNull);
      expect(vpn.commandPending, false);
      expect(bridge.disconnects, 1);
    },
  );

  test(
    'event stream loss clears verified state and retains a stop action',
    () async {
      await vpn.initialize();
      bridge.emit(running());
      bridge.states.addError(StateError('private content must never reach UI'));
      expect(vpn.status.phase, VpnPhase.error);
      expect(vpn.status.processCrashProtection, false);
      expect(vpn.canDisconnect, true);
      expect(vpn.lastErrorCode, 'ipc_disconnected');
    },
  );

  test('repeated connect is suppressed while permission is pending', () async {
    await vpn.initialize();
    final permission = Completer<void>();
    bridge.connectResult = permission.future;
    final pending = vpn.connect(profile);
    await vpn.connect(profile);
    expect(bridge.connects, 1);
    permission.complete();
    await pending;
  });

  test('effective exclusions reload and active changes are rejected', () async {
    bridge.excluded = {'org.example.browser'};
    await vpn.initialize();
    await vpn.loadExclusions();
    expect(vpn.exclusions, {'org.example.browser'});
    bridge.emit(running());
    await expectLater(vpn.setExclusions({}), throwsA(isA<VpnFailure>()));
    expect(bridge.excluded, {'org.example.browser'});
  });

  test(
    'native rejection remains visible after authoritative refresh',
    () async {
      await vpn.initialize();
      bridge.connectResult = Future.error(
        const VpnFailure('permission_denied'),
      );
      await vpn.connect(profile);
      expect(vpn.status.phase, VpnPhase.disconnected);
      expect(vpn.lastErrorCode, 'permission_denied');
      expect(vpn.canDisconnect, false);
    },
  );

  test('policy write excludes concurrent connect and freezes input', () async {
    await vpn.initialize();
    final written = Completer<void>();
    bridge.policyWrite = written.future;
    final ids = {'org.example.excluded'};
    final save = vpn.setExclusions(ids);
    ids.clear();
    await vpn.connect(profile);
    expect(bridge.connects, 0);
    expect(vpn.commandPending, true);
    await expectLater(vpn.setExclusions({}), throwsA(isA<VpnFailure>()));
    written.complete();
    await save;
    expect(vpn.commandPending, false);
    expect(bridge.excluded, {'org.example.excluded'});
    expect(vpn.exclusions, bridge.excluded);
  });

  test('late policy read cannot overwrite a completed write', () async {
    await vpn.initialize();
    final oldRead = Completer<Set<String>>();
    bridge.policyRead = oldRead.future;
    final load = vpn.loadExclusions();
    await vpn.setExclusions({'org.example.excluded'});
    oldRead.complete({'org.example.old'});
    await load;
    expect(vpn.exclusions, {'org.example.excluded'});
  });

  test(
    'failed policy write releases connect and preserves effective policy',
    () async {
      bridge.excluded = {'org.example.excluded'};
      await vpn.initialize();
      bridge.policyWrite = Future.error(
        const VpnFailure('exclusions_rejected'),
      );
      await expectLater(vpn.setExclusions({}), throwsA(isA<VpnFailure>()));
      expect(vpn.commandPending, false);
      expect(vpn.exclusions, {'org.example.excluded'});
    },
  );

  test(
    'traffic from a previous connection is not displayed after reconnect',
    () async {
      await vpn.initialize();
      bridge.emit(running());
      bridge.statistics.add(
        const TrafficStats(uploadBytes: 123, downloadBytes: 456),
      );
      expect(vpn.statisticsAvailable, true);
      bridge.emit(off);
      expect(vpn.statisticsAvailable, false);
      bridge.statistics.add(
        const TrafficStats(uploadBytes: 999, downloadBytes: 999),
      );
      expect(vpn.statisticsAvailable, false);
      bridge.emit(running());
      expect(vpn.statisticsAvailable, false);
      expect(vpn.stats.uploadBytes, 0);
      bridge.statistics.add(
        const TrafficStats(uploadBytes: 2, downloadBytes: 4),
      );
      expect(vpn.statisticsAvailable, true);
      bridge.states.addError(const VpnFailure('channel_closed'));
      expect(vpn.statisticsAvailable, false);
      expect(vpn.stats.downloadBytes, 0);
    },
  );
}
