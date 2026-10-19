import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show ModeBridge, profile, otherProfile;

class _AutomaticBridge extends ModeBridge {
  final attempts = <String>[];
  Completer<void>? acknowledgement;

  void phase(ConnectionProfile profile, VpnPhase phase, {String? error}) =>
      emit(
        VpnStatus(
          phase: phase,
          processCrashProtection: true,
          activeProfileId: profile.id,
          errorCode: error,
          systemProxySupported: true,
        ),
      );

  @override
  Future<void> connectInMode(ConnectionProfile value, VpnMode mode) async {
    attempts.add(value.id);
    phase(value, VpnPhase.connecting);
    await acknowledgement?.future;
  }

  @override
  Future<void> reconnect(ConnectionProfile value, VpnMode mode) async {
    attempts.add(value.id);
    reconfigurations.add((value.id, mode));
    phase(value, VpnPhase.connecting);
    await acknowledgement?.future;
  }
}

class _NativeAutomaticBridge extends _AutomaticBridge
    implements AutomaticSelectionBridge {
  @override
  bool get supportsAutomaticSelection => true;
  final nativeGroups = <List<String>>[];
  Completer<void>? clearAcknowledgement;
  int clears = 0;

  @override
  Future<void> connectAutomatic(
    ConnectionProfile primary,
    List<ConnectionProfile> candidates,
    VpnMode mode, {
    required bool replace,
  }) async {
    nativeGroups.add(candidates.map((profile) => profile.id).toList());
    if (replace) {
      await reconnect(primary, mode);
    } else {
      await connectInMode(primary, mode);
    }
  }

  @override
  Future<void> clearAutomaticSelection() async {
    clears++;
    await clearAcknowledgement?.future;
  }
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _AutomaticBridge bridge;
  late VpnController vpn;
  setUp(() async {
    bridge = _AutomaticBridge();
    vpn = VpnController(bridge);
    await vpn.initialize();
  });
  tearDown(() async {
    vpn.dispose();
    await bridge.close();
  });

  test(
    'waits for native HTTPS state, then replaces failed primary atomically',
    () async {
      expect(
        await vpn.startAutomaticSelection([profile, otherProfile]),
        isTrue,
      );
      expect(vpn.status.phase, VpnPhase.connecting);
      expect(bridge.attempts, [profile.id]);
      bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      await settle();
      expect(bridge.attempts, [profile.id, otherProfile.id]);
      expect(bridge.reconfigurations.single.$1, otherProfile.id);
      expect(bridge.disconnects, 0);
      bridge.active(otherProfile);
      await settle();
      expect(vpn.automaticSelectionEnabled, isTrue);
      expect(vpn.status.activeProfileId, otherProfile.id);
    },
  );

  test(
    'Windows live health failure uses reconnect and never disconnect',
    () async {
      await vpn.startAutomaticSelection([profile, otherProfile]);
      bridge.active(profile);
      await settle();
      bridge.phase(
        profile,
        VpnPhase.reconnecting,
        error: 'transport_unreachable',
      );
      await settle();
      expect(bridge.reconfigurations.single.$1, otherProfile.id);
      expect(bridge.disconnects, 0);
    },
  );

  for (final code in [
    'guard_arm_failed',
    'native_storage_unavailable',
    'protect_failed',
    'permission_denied',
  ]) {
    test('does not retry security or permission failure $code', () async {
      await vpn.startAutomaticSelection([profile, otherProfile]);
      bridge.phase(profile, VpnPhase.blocked, error: code);
      await settle();
      expect(bridge.attempts, [profile.id]);
      expect(vpn.automaticSelectionEnabled, isFalse);
      expect(bridge.disconnects, 0);
    });
  }

  test('all failed candidates back off and retain native protection', () async {
    await vpn.startAutomaticSelection([profile, otherProfile]);
    bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
    await settle();
    bridge.phase(otherProfile, VpnPhase.blocked, error: 'tunnel_https_failed');
    await settle();
    expect(bridge.attempts, [profile.id, otherProfile.id]);
    expect(vpn.automaticSelectionEnabled, isTrue);
    expect(bridge.disconnects, 0);
    vpn.stopAutomaticSelection();
    await settle();
    expect(bridge.attempts.length, 2);
  });

  test(
    'manual selection supersedes pending auto without reviving stale result',
    () async {
      bridge.acknowledgement = Completer<void>();
      final original = vpn.startAutomaticSelection([profile, otherProfile]);
      final manual = vpn.requestConnection(otherProfile);
      bridge.acknowledgement!.complete();
      await original;
      await manual;
      bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      await settle();
      expect(vpn.automaticSelectionEnabled, isFalse);
      expect(bridge.attempts, [profile.id, otherProfile.id]);
      expect(bridge.disconnects, 0);
    },
  );

  test('mode switch retains automatic group and switches atomically', () async {
    await vpn.startAutomaticSelection([profile, otherProfile]);
    bridge.active(profile);
    await settle();
    expect(await vpn.changeMode(VpnMode.proxy, profile: profile), isTrue);
    expect(vpn.automaticSelectionEnabled, isTrue);
    expect(bridge.reconfigurations.last, (profile.id, VpnMode.proxy));
  });

  test(
    'stale health from previous candidate cannot cause another switch',
    () async {
      await vpn.startAutomaticSelection([profile, otherProfile]);
      bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      await settle();
      bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      await settle();
      expect(bridge.attempts, [profile.id, otherProfile.id]);
    },
  );

  test(
    'refresh removal disables auto without implicitly disconnecting',
    () async {
      await vpn.startAutomaticSelection([profile, otherProfile]);
      vpn.updateAutomaticCandidates([otherProfile]);
      expect(vpn.automaticSelectionEnabled, isFalse);
      expect(bridge.attempts, [profile.id]);
      expect(bridge.disconnects, 0);
    },
  );

  test('IPC loss disables auto and does not mutate native state', () async {
    await vpn.startAutomaticSelection([profile, otherProfile]);
    bridge.states.addError(const VpnFailure('ipc_disconnected'));
    await settle();
    expect(vpn.automaticSelectionEnabled, isFalse);
    expect(bridge.attempts, [profile.id]);
    expect(bridge.disconnects, 0);
  });

  Future<_NativeAutomaticBridge> useNativeGroupBridge() async {
    vpn.dispose();
    await bridge.close();
    final native = _NativeAutomaticBridge();
    bridge = native;
    vpn = VpnController(native);
    await vpn.initialize();
    return native;
  }

  test(
    'native groups have exactly one selector and no competing Dart retry',
    () async {
      final native = await useNativeGroupBridge();
      await vpn.startAutomaticSelection([profile, otherProfile]);
      native.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      await settle();
      expect(native.nativeGroups.single, [profile.id, otherProfile.id]);
      expect(native.attempts, [profile.id]);
      expect(native.disconnects, 0);
    },
  );

  test(
    'newest manual request waits for native group clear before reconnect',
    () async {
      final native = await useNativeGroupBridge();
      await vpn.startAutomaticSelection([profile, otherProfile]);
      native.active(profile);
      await settle();
      native.clearAcknowledgement = Completer<void>();
      final clearing = vpn.disableAutomaticSelection();
      final superseded = vpn.requestConnection(profile);
      final latest = vpn.requestConnection(otherProfile);
      await settle();
      expect(native.attempts, [profile.id]);
      native.clearAcknowledgement!.complete();
      await clearing;
      expect(await superseded, isFalse);
      expect(await latest, isTrue);
      expect(native.attempts, [profile.id, otherProfile.id]);
      expect(native.clears, 1);
      expect(native.disconnects, 0);
    },
  );

  test(
    'native mode switch carries immutable automatic group snapshot',
    () async {
      final native = await useNativeGroupBridge();
      await vpn.startAutomaticSelection([profile, otherProfile]);
      native.active(profile);
      await settle();
      vpn.updateAutomaticCandidates([profile]);
      await vpn.changeMode(VpnMode.proxy, profile: profile);
      expect(native.nativeGroups, [
        [profile.id, otherProfile.id],
        [profile.id, otherProfile.id],
      ]);
      expect(native.reconfigurations.last.$2, VpnMode.proxy);
    },
  );

  test(
    'oversized group is rejected rather than silently dropping entries',
    () async {
      expect(
        await vpn.startAutomaticSelection(List.filled(33, profile)),
        isFalse,
      );
      expect(bridge.attempts, isEmpty);
    },
  );

  test('reattaches confirmed native group without connecting', () async {
    final native = await useNativeGroupBridge();
    native.emit(
      VpnStatus(
        phase: VpnPhase.connected,
        processCrashProtection: true,
        activeProfileId: otherProfile.id,
        systemProxySupported: true,
        automaticSelection: true,
      ),
    );
    expect(vpn.automaticSelectionEnabled, isTrue);
    expect(vpn.adoptAutomaticSelection([profile, otherProfile]), isTrue);
    expect(native.attempts, isEmpty);
    await vpn.changeMode(VpnMode.proxy, profile: otherProfile);
    expect(native.nativeGroups.single, [profile.id, otherProfile.id]);
    expect(native.attempts, [otherProfile.id]);
  });

  test('cannot guess restored group without active member', () async {
    final native = await useNativeGroupBridge();
    native.emit(
      VpnStatus(
        phase: VpnPhase.connected,
        processCrashProtection: true,
        activeProfileId: otherProfile.id,
        systemProxySupported: true,
        automaticSelection: true,
      ),
    );
    expect(vpn.adoptAutomaticSelection([profile]), isFalse);
    expect(native.attempts, isEmpty);
  });

  Future<void> initializeInTestZone() async {
    vpn.dispose();
    await bridge.close();
    bridge = _AutomaticBridge();
    vpn = VpnController(bridge);
    await vpn.initialize();
  }

  testWidgets('exhausted round retries only after cooldown', (tester) async {
    await initializeInTestZone();
    await vpn.startAutomaticSelection([profile, otherProfile]);
    bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    bridge.phase(otherProfile, VpnPhase.blocked, error: 'tunnel_https_failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 29));
    expect(bridge.attempts, [profile.id, otherProfile.id]);
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.attempts, [profile.id, otherProfile.id, profile.id]);
    expect(bridge.disconnects, 0);
    vpn.stopAutomaticSelection();
  });

  testWidgets(
    'native recovery cancels cooldown without switching healthy node',
    (tester) async {
      await vpn.startAutomaticSelection([profile, otherProfile]);
      bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      bridge.phase(
        otherProfile,
        VpnPhase.blocked,
        error: 'tunnel_https_failed',
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      bridge.active(otherProfile);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 31));
      expect(bridge.attempts, [profile.id, otherProfile.id]);
      expect(vpn.automaticSelectionEnabled, isTrue);
    },
  );

  testWidgets('security failure during cooldown cancels further retries', (
    tester,
  ) async {
    await initializeInTestZone();
    await vpn.startAutomaticSelection([profile, otherProfile]);
    bridge.phase(profile, VpnPhase.blocked, error: 'tunnel_https_failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    bridge.phase(otherProfile, VpnPhase.blocked, error: 'tunnel_https_failed');
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    bridge.phase(
      otherProfile,
      VpnPhase.blocked,
      error: 'native_storage_unavailable',
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 31));
    expect(bridge.attempts, [profile.id, otherProfile.id]);
    expect(vpn.automaticSelectionEnabled, isFalse);
  });
}
