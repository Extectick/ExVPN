import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge, profile, otherProfile;

class _AndroidBridge extends FakeBridge implements ServerReconnectBridge {
  @override
  bool get supportsServerReconnect => true;
  int replacements = 0;

  @override
  Future<void> connect(ConnectionProfile value) async {
    connects++;
    emit(
      VpnStatus(
        phase: VpnPhase.connecting,
        processCrashProtection: false,
        activeProfileId: value.id,
      ),
    );
    await connectResult;
  }

  @override
  Future<void> reconnectServer(ConnectionProfile value) async {
    replacements++;
    emit(
      VpnStatus(
        phase: VpnPhase.connecting,
        processCrashProtection: false,
        activeProfileId: value.id,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android supersedes connecting server without a UI disconnect',
    () async {
      final bridge = _AndroidBridge();
      final vpn = VpnController(bridge);
      final gate = Completer<void>();
      bridge.connectResult = gate.future;
      await vpn.initialize();
      expect(vpn.modeSwitchSupported, isFalse);
      final first = vpn.requestConnection(profile);
      final last = vpn.requestConnection(otherProfile);
      expect(await first, isFalse);
      expect(vpn.desiredProfileId, otherProfile.id);
      gate.complete();
      expect(await last, isTrue);
      expect(bridge.connects, 1);
      expect(bridge.replacements, 1);
      expect(bridge.disconnects, 0);
      expect(vpn.status.phase, VpnPhase.connecting);
      expect(vpn.status.activeProfileId, otherProfile.id);
      expect(vpn.status.processCrashProtection, isFalse);
      expect(
        await vpn.changeMode(VpnMode.proxy, profile: otherProfile),
        isFalse,
      );
      vpn.dispose();
      await bridge.close();
    },
  );

  test('Android disconnect cancels an obsolete queued replacement', () async {
    final bridge = _AndroidBridge();
    final vpn = VpnController(bridge);
    final gate = Completer<void>();
    bridge.connectResult = gate.future;
    await vpn.initialize();
    final first = vpn.requestConnection(profile);
    final last = vpn.requestConnection(otherProfile);
    await vpn.disconnect();
    gate.complete();
    expect(await first, isFalse);
    expect(await last, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.replacements, 0);
    expect(bridge.disconnects, 1);
    expect(vpn.status.phase, VpnPhase.disconnected);
    vpn.dispose();
    await bridge.close();
  });

  test('Android bridge requests a native VPN-only replacement', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('test/android-server-reconnect');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? actual;
    messenger.setMockMethodCallHandler(channel, (call) async {
      actual = call;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final bridge = NativeVpnBridge(methods: channel);
    expect(bridge.supportsConnectionModes, isFalse);
    expect(bridge.supportsServerReconnect, isTrue);
    await bridge.reconnectServer(otherProfile);
    expect(actual?.method, 'reconnect');
    expect((actual!.arguments as Map)['mode'], 'vpn');
    expect((actual!.arguments as Map)['profile'], otherProfile.toNativeJson());
  });
}
