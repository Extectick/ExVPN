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
final otherProfile = const SubscriptionParser()
    .parse(
      'vless://00000000-0000-4000-8000-000000000002@other.invalid:443?security=tls#Other',
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

class ModeBridge extends FakeBridge implements ConnectionModeBridge {
  ModeBridge() {
    current = const VpnStatus(
      phase: VpnPhase.disconnected,
      processCrashProtection: false,
      systemProxySupported: true,
    );
  }

  @override
  bool get supportsConnectionModes => true;
  final modeConnects = <(String, VpnMode)>[];
  final reconfigurations = <(String, VpnMode)>[];
  Future<void>? reconnectResult;

  @override
  Future<void> connectInMode(ConnectionProfile value, VpnMode mode) async {
    modeConnects.add((value.id, mode));
    await (connectResult ?? Future.value());
  }

  @override
  Future<void> reconnect(ConnectionProfile value, VpnMode mode) async {
    reconfigurations.add((value.id, mode));
    await (reconnectResult ?? Future.value());
  }

  void active(ConnectionProfile value, {VpnMode mode = VpnMode.vpn}) => emit(
    VpnStatus(
      phase: VpnPhase.connected,
      processCrashProtection: mode == VpnMode.vpn,
      systemProxySupported: true,
      activeProfileId: value.id,
      connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      mode: mode,
    ),
  );
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

  group('application restart reservation', () {
    Matcher failure(String code) =>
        isA<VpnFailure>().having((error) => error.code, 'code', code);

    test('requires initialized state and no in-flight command', () async {
      var calls = 0;
      Future<void> handoff(bool Function() safe) async => calls++;
      await expectLater(
        vpn.runForApplicationRestart(handoff),
        throwsA(failure('restart_busy')),
      );
      await vpn.initialize();
      final connection = Completer<void>();
      bridge.connectResult = connection.future;
      final pending = vpn.connect(profile);
      await expectLater(
        vpn.runForApplicationRestart(handoff),
        throwsA(failure('restart_busy')),
      );
      expect(calls, 0);
      connection.complete();
      await pending;
    });

    test(
      'freezes commands and other reservations without stopping VPN',
      () async {
        await vpn.initialize();
        bridge.emit(running());
        final before = vpn.status;
        await vpn.runForApplicationRestart((safe) async {
          expect(safe(), isTrue);
          expect(vpn.applicationRestartPending, isTrue);
          expect(vpn.commandPending, isTrue);
          expect(vpn.canApplyDataUpdate, isFalse);
          await vpn.connect(otherProfile);
          await vpn.disconnect();
          expect(
            await vpn.changeMode(VpnMode.proxy, profile: profile),
            isFalse,
          );
          expect(await vpn.switchServer(otherProfile), isFalse);
          await expectLater(
            vpn.setExclusions({'app'}),
            throwsA(failure('reconnect_required')),
          );
          await expectLater(
            vpn.runWhileDisconnected((safe) async {}),
            throwsA(failure('update_requires_disconnected')),
          );
          await expectLater(
            vpn.runForApplicationRestart((safe) async {}),
            throwsA(failure('restart_busy')),
          );
          expect(safe(), isTrue);
        });
        expect(vpn.status, same(before));
        expect(bridge.connects, 0);
        expect(bridge.disconnects, 0);
        expect(vpn.applicationRestartPending, isFalse);
        expect(vpn.commandPending, isFalse);
      },
    );

    test(
      'UI-only restart permits a live proxy and native state events',
      () async {
        await vpn.initialize();
        bridge.emit(
          VpnStatus(
            phase: VpnPhase.connected,
            processCrashProtection: false,
            activeProfileId: profile.id,
            mode: VpnMode.proxy,
            systemProxySupported: true,
          ),
        );
        await vpn.runForApplicationRestart((safe) async {
          expect(vpn.mode, VpnMode.proxy);
          bridge.emit(
            const VpnStatus(
              phase: VpnPhase.error,
              processCrashProtection: false,
              mode: VpnMode.proxy,
              cleanupRequired: true,
              errorCode: 'proxy_unreachable',
            ),
          );
          expect(safe(), isTrue);
          vpn.commitApplicationRestart();
        });
        expect(vpn.applicationRestartPending, isTrue);
        expect(vpn.mode, VpnMode.proxy);
        expect(vpn.status.cleanupRequired, isTrue);
        expect(bridge.disconnects, 0);
      },
    );

    test('active and cleanup states refuse a full installer', () async {
      await vpn.initialize();
      var calls = 0;
      for (final state in [
        running(),
        const VpnStatus(phase: VpnPhase.blocked, processCrashProtection: true),
        const VpnStatus(
          phase: VpnPhase.disconnected,
          processCrashProtection: false,
          cleanupRequired: true,
        ),
        const VpnStatus(
          phase: VpnPhase.error,
          processCrashProtection: false,
          errorCode: 'ipc_unavailable',
        ),
      ]) {
        bridge.emit(state);
        await expectLater(
          vpn.runForApplicationRestart(
            (safe) async => calls++,
            requireDisconnected: true,
          ),
          throwsA(failure('update_requires_disconnected')),
        );
        expect(vpn.applicationRestartPending, isFalse);
      }
      expect(calls, 0);
      expect(bridge.disconnects, 0);
    });

    test('full installer checks authoritative status before handoff', () async {
      await vpn.initialize();
      bridge.current = running();
      var calls = 0;
      await expectLater(
        vpn.runForApplicationRestart(
          (safe) async => calls++,
          requireDisconnected: true,
        ),
        throwsA(failure('update_requires_disconnected')),
      );
      expect(calls, 0);
      expect(vpn.status.phase, VpnPhase.connected);
      expect(vpn.applicationRestartPending, isFalse);
      expect(bridge.disconnects, 0);
    });

    test(
      'full installer detects a transient native start before commit',
      () async {
        await vpn.initialize();
        await vpn.runForApplicationRestart((safe) async {
          expect(safe(), isTrue);
          bridge.emit(running());
          bridge.emit(off);
          expect(safe(), isFalse);
          expect(
            vpn.commitApplicationRestart,
            throwsA(failure('update_requires_disconnected')),
          );
        }, requireDisconnected: true);
        expect(vpn.applicationRestartPending, isFalse);
        expect(bridge.disconnects, 0);
      },
    );

    test('failed flush or handoff releases the reservation', () async {
      await vpn.initialize();
      await expectLater(
        vpn.runForApplicationRestart((safe) async {
          throw StateError('synthetic persistence failure');
        }),
        throwsStateError,
      );
      expect(vpn.applicationRestartPending, isFalse);
      await vpn.connect(profile);
      expect(bridge.connects, 1);
    });

    test(
      'accepted handoff stays frozen across return and exit errors',
      () async {
        await vpn.initialize();
        await expectLater(
          vpn.runForApplicationRestart((safe) async {
            vpn.commitApplicationRestart();
            throw StateError('synthetic exit acknowledgement failure');
          }, requireDisconnected: true),
          throwsStateError,
        );
        expect(vpn.applicationRestartPending, isTrue);
        expect(vpn.commandPending, isTrue);
        await vpn.connect(profile);
        await vpn.disconnect();
        expect(bridge.connects, 0);
        expect(bridge.disconnects, 0);
        await expectLater(
          vpn.runForApplicationRestart((safe) async {}),
          throwsA(failure('restart_busy')),
        );
        expect(
          vpn.commitApplicationRestart,
          throwsA(failure('update_requires_disconnected')),
        );
      },
    );

    test('an active data update cannot overlap restart preparation', () async {
      await vpn.initialize();
      await vpn.runWhileDisconnected((safe) async {
        await expectLater(
          vpn.runForApplicationRestart((safe) async {}),
          throwsA(failure('restart_busy')),
        );
        expect(safe(), isTrue);
      });
      expect(vpn.commandPending, isFalse);
    });
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

  group('atomic native server and mode changes', () {
    late ModeBridge native;

    setUp(() async {
      vpn.dispose();
      await bridge.close();
      native = ModeBridge();
      bridge = native;
      vpn = VpnController(native);
      await vpn.initialize();
    });

    test(
      'idle mode choice survives refresh and selects next connect mode',
      () async {
        expect(vpn.modeSwitchSupported, isTrue);
        expect(await vpn.changeMode(VpnMode.proxy), isTrue);
        await vpn.refresh();
        expect(vpn.mode, VpnMode.proxy);
        expect(native.reconfigurations, isEmpty);
        expect(native.modeConnects, isEmpty);
        await vpn.connect(profile);
        expect(native.modeConnects, [(profile.id, VpnMode.proxy)]);
        expect(native.connects, 0);
        expect(vpn.status.phase, VpnPhase.disconnected);
      },
    );

    test(
      'old service without advertised mode capability stays VPN-only',
      () async {
        native.emit(off);
        expect(vpn.modeSwitchSupported, isFalse);
        expect(await vpn.changeMode(VpnMode.proxy), isFalse);
        await vpn.connect(profile);
        expect(native.connects, 1);
        expect(native.modeConnects, isEmpty);
        native.emit(running());
        expect(await vpn.switchServer(otherProfile), isFalse);
        expect(native.reconfigurations, isEmpty);
        expect(native.disconnects, 0);
      },
    );

    test(
      'active server selection uses one reconfigure, no disconnect gap',
      () async {
        native.active(profile);
        expect(await vpn.switchServer(otherProfile), isTrue);
        expect(native.reconfigurations, [(otherProfile.id, VpnMode.vpn)]);
        expect(native.disconnects, 0);
        expect(native.connects, 0);
        expect(native.modeConnects, isEmpty);
        expect(vpn.status.activeProfileId, profile.id);
        expect(vpn.status.phase, VpnPhase.connected);
        native.active(otherProfile);
        expect(vpn.status.activeProfileId, otherProfile.id);
      },
    );

    test('clicking active server or mode does not restart the core', () async {
      native.active(profile, mode: VpnMode.proxy);
      expect(await vpn.switchServer(profile), isTrue);
      expect(await vpn.changeMode(VpnMode.proxy), isTrue);
      expect(native.reconfigurations, isEmpty);
      expect(native.disconnects, 0);
    });

    test(
      'rapid server and mode requests cannot overlap reconfiguration',
      () async {
        native.active(profile);
        final stopped = Completer<void>();
        native.reconnectResult = stopped.future;
        final first = vpn.switchServer(otherProfile);
        expect(vpn.commandPending, isTrue);
        expect(await vpn.switchServer(otherProfile), isFalse);
        expect(await vpn.changeMode(VpnMode.proxy, profile: profile), isFalse);
        await vpn.connect(otherProfile);
        expect(native.reconfigurations.length, 1);
        expect(native.modeConnects, isEmpty);
        stopped.complete();
        expect(await first, isTrue);
        expect(vpn.commandPending, isFalse);
      },
    );

    test('active mode change reconfigures the exact active profile', () async {
      native.active(profile);
      expect(
        await vpn.changeMode(VpnMode.proxy, profile: otherProfile),
        isFalse,
      );
      expect(native.reconfigurations, isEmpty);
      expect(vpn.lastErrorCode, 'mode_profile_mismatch');
      expect(await vpn.changeMode(VpnMode.proxy, profile: profile), isTrue);
      expect(native.reconfigurations, [(profile.id, VpnMode.proxy)]);
      expect(vpn.mode, VpnMode.vpn);
      native.active(profile, mode: VpnMode.proxy);
      expect(vpn.mode, VpnMode.proxy);
      expect(native.disconnects, 0);
    });

    test('failed native stop never retries via a second connect', () async {
      native.active(profile);
      native.reconnectResult = Future.error(const VpnFailure('core_failed'));
      expect(await vpn.switchServer(otherProfile), isFalse);
      expect(native.reconfigurations.length, 1);
      expect(native.disconnects, 0);
      expect(native.modeConnects, isEmpty);
      expect(vpn.status.activeProfileId, profile.id);
      expect(vpn.status.phase, VpnPhase.connected);
      expect(vpn.lastErrorCode, 'core_failed');
      expect(vpn.commandPending, isFalse);
    });

    test(
      'blocked reconfigure result stays blocked and preserves stop action',
      () async {
        native.active(profile);
        final finish = Completer<void>();
        native.reconnectResult = finish.future;
        final changed = vpn.changeMode(VpnMode.proxy, profile: profile);
        native.emit(
          VpnStatus(
            phase: VpnPhase.blocked,
            processCrashProtection: true,
            activeProfileId: profile.id,
            mode: VpnMode.vpn,
            systemProxySupported: true,
            errorCode: 'proxy_setup_failed',
          ),
        );
        finish.completeError(const VpnFailure('proxy_setup_failed'));
        expect(await changed, isFalse);
        expect(vpn.mode, VpnMode.vpn);
        expect(vpn.status.phase, VpnPhase.blocked);
        expect(vpn.canDisconnect, isTrue);
        expect(await vpn.switchServer(otherProfile), isFalse);
        expect(native.reconfigurations.length, 1);
        expect(native.disconnects, 0);
      },
    );

    test(
      'native failure after acknowledgement is not reported as accepted',
      () async {
        native.active(profile);
        final finish = Completer<void>();
        native.reconnectResult = finish.future;
        final changed = vpn.changeMode(VpnMode.proxy, profile: profile);
        native.emit(
          const VpnStatus(
            phase: VpnPhase.disconnected,
            processCrashProtection: false,
            systemProxySupported: true,
            errorCode: 'proxy_setup_failed',
          ),
        );
        finish.complete();
        expect(await changed, isFalse);
        expect(vpn.mode, VpnMode.vpn);
        expect(vpn.status.phase, VpnPhase.disconnected);
        expect(vpn.lastErrorCode, 'proxy_setup_failed');
        expect(native.reconfigurations.length, 1);
        expect(native.modeConnects, isEmpty);
        expect(native.disconnects, 0);
      },
    );

    test(
      'unknown state never starts a reconfiguration or new connection',
      () async {
        native.active(profile, mode: VpnMode.proxy);
        native.states.addError(const VpnFailure('channel_closed'));
        expect(vpn.mode, VpnMode.proxy);
        expect(await vpn.switchServer(otherProfile), isFalse);
        expect(await vpn.changeMode(VpnMode.vpn, profile: profile), isFalse);
        await vpn.connect(otherProfile);
        expect(native.reconfigurations, isEmpty);
        expect(native.modeConnects, isEmpty);
        expect(vpn.status.phase, VpnPhase.error);
      },
    );

    test(
      'asynchronous connecting acknowledgement does not invent success',
      () async {
        native.active(profile);
        final finish = Completer<void>();
        native.reconnectResult = finish.future;
        final changed = vpn.switchServer(otherProfile);
        native.emit(
          VpnStatus(
            phase: VpnPhase.reconnecting,
            processCrashProtection: true,
            activeProfileId: otherProfile.id,
            systemProxySupported: true,
          ),
        );
        finish.complete();
        expect(await changed, isTrue);
        expect(vpn.status.phase, VpnPhase.reconnecting);
        expect(await vpn.switchServer(profile), isFalse);
        expect(native.reconfigurations.length, 1);
      },
    );

    test(
      'dispose ignores pending change completion without a follow-up',
      () async {
        native.active(profile);
        final finish = Completer<void>();
        native.reconnectResult = finish.future;
        final changed = vpn.switchServer(otherProfile);
        vpn.dispose();
        // Replace the disposed controller for the common tearDown.
        vpn = VpnController(native);
        finish.complete();
        expect(await changed, isFalse);
        expect(native.reconfigurations.length, 1);
        expect(native.modeConnects, isEmpty);
      },
    );
  });

  test(
    'legacy and old-service capabilities never pretend to support proxy',
    () async {
      await vpn.initialize();
      expect(vpn.modeSwitchSupported, isFalse);
      expect(await vpn.changeMode(VpnMode.proxy), isFalse);
      expect(vpn.mode, VpnMode.vpn);
      expect(vpn.lastErrorCode, 'mode_unsupported');
      await vpn.connect(profile);
      expect(bridge.connects, 1);
      bridge.emit(running());
      expect(await vpn.switchServer(otherProfile), isFalse);
      expect(bridge.disconnects, 0);
    },
  );

  test(
    'startup proxy application error with active native core can be stopped',
    () async {
      bridge.current = VpnStatus(
        phase: VpnPhase.error,
        processCrashProtection: false,
        activeProfileId: profile.id,
        mode: VpnMode.proxy,
        systemProxySupported: true,
        errorCode: 'proxy_setup_failed',
      );
      await vpn.initialize();
      expect(vpn.canDisconnect, isTrue);
      expect(vpn.mode, VpnMode.proxy);
      await vpn.connect(otherProfile);
      expect(bridge.connects, 0);
      await vpn.disconnect();
      expect(bridge.disconnects, 1);
      expect(vpn.canDisconnect, isFalse);
    },
  );

  test(
    'local proxy cleanup remains possible with no service or active ID',
    () async {
      bridge.current = const VpnStatus(
        phase: VpnPhase.error,
        processCrashProtection: false,
        mode: VpnMode.proxy,
        systemProxySupported: true,
        cleanupRequired: true,
        errorCode: 'service_unavailable',
      );
      await vpn.initialize();
      expect(vpn.canDisconnect, isTrue);
      expect(vpn.mode, VpnMode.proxy);
      bridge.states.addError(const VpnFailure('channel_closed'));
      expect(vpn.status.cleanupRequired, isTrue);
      expect(vpn.canDisconnect, isTrue);
      await vpn.connect(otherProfile);
      expect(bridge.connects, 0);
      await vpn.disconnect();
      expect(bridge.disconnects, 1);
      expect(vpn.canDisconnect, isFalse);
      expect(vpn.status.cleanupRequired, isFalse);
    },
  );
}
