import 'dart:async';

import 'package:exvpn/services/desktop_tray.dart';
import 'package:exvpn/services/native_vpn_bridge.dart' show VpnFailure;
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _input =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Private%20name';
const _off = VpnStatus(
  phase: VpnPhase.disconnected,
  processCrashProtection: false,
);
const _connected = VpnStatus(
  phase: VpnPhase.connected,
  processCrashProtection: false,
);
const _blocked = VpnStatus(
  phase: VpnPhase.blocked,
  processCrashProtection: true,
);

class _Bridge implements VpnBridge {
  final states = StreamController<VpnStatus>.broadcast(sync: true);
  final stats = StreamController<TrafficStats>.broadcast(sync: true);
  VpnStatus current = _off;
  Future<VpnStatus>? snapshot;
  Future<void>? connecting;
  int connects = 0;
  int disconnects = 0;
  void emit(VpnStatus status) {
    current = status;
    states.add(status);
  }

  @override
  Stream<VpnStatus> get statuses => states.stream;
  @override
  Stream<TrafficStats> get traffic => stats.stream;
  @override
  Future<VpnStatus> getStatus() => snapshot ?? Future.value(current);
  @override
  Future<void> connect(ConnectionProfile profile) async {
    connects++;
    await connecting;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    emit(_off);
  }

  @override
  Future<String> coreVersion() async => 'test';
  @override
  Future<Set<String>> getExclusions() async => {};
  @override
  Future<void> setExclusions(Set<String> ids) async {}
  @override
  Future<List<ApplicationIdentity>> listApplications() async => [];
  @override
  Future<void> openSystemProtectionSettings() async {}
  @override
  Future<ProbeResult> probe(ConnectionProfile profile) async =>
      const ProbeResult(reachable: false);
}

class _Tray implements DesktopTray {
  final updates = <TrayState>[];
  Future<void> Function(String)? command;
  Future<void>? updateGate;
  bool failUpdate = false;
  int shows = 0;
  int exits = 0;
  @override
  void onCommand(Future<void> Function(String command)? handler) {
    command = handler;
  }

  @override
  Future<void> update(TrayState state) async {
    if (failUpdate) throw StateError('Shell unavailable');
    updates.add(state);
    await updateGate;
  }

  @override
  Future<void> showWindow() async {
    shows++;
  }

  @override
  Future<void> exitApplication() async {
    exits++;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Bridge bridge;
  late VpnController vpn;
  late AppController app;
  late _Tray tray;
  DesktopTrayController? controller;
  late List<String> notices;
  var confirm = true;
  var saved = true;
  var saves = 0;
  Future<bool>? confirmation;
  Future<bool>? saving;

  void start() {
    controller = DesktopTrayController(
      app: app,
      vpn: vpn,
      tray: tray,
      confirmExit: () => confirmation ?? Future.value(confirm),
      saveBeforeExit: () {
        saves++;
        return saving ?? Future.value(saved);
      },
      showNotice: notices.add,
    );
  }

  setUp(() {
    bridge = _Bridge();
    vpn = VpnController(bridge);
    app = AppController()
      ..addSubscription(name: 'Private subscription', raw: _input);
    tray = _Tray();
    notices = [];
    confirm = true;
    saved = true;
    saves = 0;
    confirmation = null;
    saving = null;
  });
  tearDown(() async {
    controller?.dispose();
    controller = null;
    vpn.dispose();
    app.dispose();
    await bridge.states.close();
    await bridge.stats.close();
  });

  test(
    'initialization and native status govern commands; no secret labels',
    () async {
      start();
      expect(controller!.state, (
        phase: 'initializing',
        canConnect: false,
        canDisconnect: false,
      ));
      await vpn.initialize();
      await _settle();
      expect(tray.updates.last, (
        phase: 'disconnected',
        canConnect: true,
        canDisconnect: false,
      ));
      bridge.emit(_connected);
      await _settle();
      expect(tray.updates.last, (
        phase: 'connected',
        canConnect: false,
        canDisconnect: true,
      ));
      expect(tray.updates.toString(), isNot(contains('Private')));
      expect(tray.updates.toString(), isNot(contains('sample.invalid')));
    },
  );

  test('connect acceptance never manufactures connected', () async {
    await vpn.initialize();
    start();
    await controller!.handleCommand('connect');
    await _settle();
    expect(bridge.connects, 1);
    expect(bridge.disconnects, 0);
    expect(tray.updates.last.phase, 'disconnected');
  });

  test(
    'stale connect refreshes native state and never toggles off a tunnel',
    () async {
      await vpn.initialize();
      start();
      bridge.current = _connected;
      await controller!.handleCommand('connect');
      expect(bridge.connects, 0);
      expect(bridge.disconnects, 0);
      expect(controller!.state.phase, 'connected');
    },
  );

  test('stale disconnect cannot connect a disconnected client', () async {
    await vpn.initialize();
    bridge.emit(_connected);
    start();
    bridge.current = _off;
    await controller!.handleCommand('disconnect');
    expect(bridge.connects, 0);
    expect(bridge.disconnects, 0);
  });

  test(
    'unconfirmed service state refuses connect and opens the error',
    () async {
      await vpn.initialize();
      start();
      bridge.snapshot = Future.error(const VpnFailure('ipc_unavailable'));
      await controller!.handleCommand('connect');
      expect(bridge.connects, 0);
      expect(controller!.state.canConnect, false);
      expect(controller!.state.phase, 'error');
      expect(tray.shows, 1);
      expect(notices.single, contains('недоступна'));
    },
  );

  test(
    'changed selection during refresh refuses an unintended server',
    () async {
      await vpn.initialize();
      start();
      final refresh = Completer<VpnStatus>();
      bridge.snapshot = refresh.future;
      final command = controller!.handleCommand('connect');
      app.removeSubscription(app.groups.single.id);
      app.addSubscription(name: 'Replacement', raw: _input);
      refresh.complete(_off);
      await command;
      expect(bridge.connects, 0);
    },
  );

  test('duplicate and competing tray commands are coalesced', () async {
    await vpn.initialize();
    start();
    final response = Completer<void>();
    bridge.connecting = response.future;
    final first = controller!.handleCommand('connect');
    await _settle();
    await controller!.handleCommand('connect');
    await controller!.handleCommand('disconnect');
    expect(bridge.connects, 1);
    expect(bridge.disconnects, 0);
    response.complete();
    await first;
  });

  test('data update reservation prevents tray connect', () async {
    await vpn.initialize();
    start();
    await vpn.runWhileDisconnected((safe) async {
      expect(safe(), true);
      await controller!.handleCommand('connect');
      expect(controller!.state.canConnect, false);
    });
    expect(bridge.connects, 0);
  });

  test(
    'blocked state allows explicit disconnect through native controller',
    () async {
      await vpn.initialize();
      bridge.emit(_blocked);
      start();
      await controller!.handleCommand('disconnect');
      expect(bridge.disconnects, 1);
      expect(vpn.status.phase, VpnPhase.disconnected);
    },
  );

  test('empty selection and unknown commands cannot start a tunnel', () async {
    await vpn.initialize();
    app.removeSubscription(app.groups.single.id);
    start();
    expect(controller!.state.canConnect, false);
    await controller!.handleCommand('connect');
    await controller!.handleCommand('toggle');
    expect(bridge.connects, 0);
    expect(bridge.disconnects, 0);
    expect(tray.exits, 0);
  });

  test(
    'exit cancellation keeps interface, storage and VPN untouched',
    () async {
      await vpn.initialize();
      bridge.emit(_connected);
      start();
      confirm = false;
      await controller!.handleCommand('exit');
      expect(tray.shows, 1);
      expect(saves, 0);
      expect(tray.exits, 0);
      expect(bridge.disconnects, 0);
    },
  );

  test(
    'exit waits for persisted subscriptions and preserves active VPN',
    () async {
      await vpn.initialize();
      bridge.emit(_connected);
      start();
      final disk = Completer<bool>();
      saving = disk.future;
      final exit = controller!.handleCommand('exit');
      await _settle();
      expect(saves, 1);
      expect(tray.exits, 0);
      disk.complete(true);
      await exit;
      expect(tray.exits, 1);
      expect(bridge.disconnects, 0);
      expect(vpn.status.phase, VpnPhase.connected);
    },
  );

  test(
    'failed persistence refuses exit and reports a bounded message',
    () async {
      await vpn.initialize();
      start();
      saved = false;
      await controller!.handleCommand('exit');
      expect(tray.exits, 0);
      expect(notices.single, contains('сохранить подписки'));
    },
  );

  test('dispose while confirming exit prevents later exit callback', () async {
    await vpn.initialize();
    start();
    final dialog = Completer<bool>();
    confirmation = dialog.future;
    final exit = controller!.handleCommand('exit');
    await _settle();
    controller!.dispose();
    controller = null;
    dialog.complete(true);
    await exit;
    expect(tray.exits, 0);
    expect(saves, 0);
    expect(tray.command, null);
  });

  test(
    'serial publication catches latest state and ignores traffic noise',
    () async {
      await vpn.initialize();
      final gate = Completer<void>();
      tray.updateGate = gate.future;
      start();
      bridge.emit(_connected);
      bridge.emit(_blocked);
      gate.complete();
      await _settle();
      expect(tray.updates.last.phase, 'blocked');
      final count = tray.updates.length;
      bridge.stats.add(
        const TrafficStats(uploadBytes: 100, downloadBytes: 200),
      );
      await _settle();
      expect(tray.updates.length, count);
    },
  );

  test('shell update failure is isolated and a later state retries', () async {
    await vpn.initialize();
    tray.failUpdate = true;
    start();
    await _settle();
    tray.failUpdate = false;
    bridge.emit(_connected);
    await _settle();
    expect(tray.updates.last.phase, 'connected');
    expect(bridge.disconnects, 0);
  });

  test('platform transport only serializes fixed state', () async {
    const channel = MethodChannel('exvpn/tray');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final native = WindowsDesktopTray();
    await native.update((
      phase: 'blocked',
      canConnect: false,
      canDisconnect: true,
    ));
    await native.showWindow();
    await native.exitApplication();
    expect(calls.map((c) => c.method), ['update', 'show', 'exit']);
    expect(calls.first.arguments, {
      'phase': 'blocked',
      'canConnect': false,
      'canDisconnect': true,
    });
  });
}
