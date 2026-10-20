import 'dart:async';

import 'package:exvpn/main.dart';
import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/app_update_strip.dart';
import 'package:exvpn/src/appearance.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_updates_test.dart' show FakeFullUpdates, FakePatchUpdates;
import 'vpn_controller_test.dart' show FakeBridge, off, running;

class _Appearance extends AppearanceController {
  _Appearance() : super(persist: false);
  int flushes = 0;
  @override
  Future<void> flush() async => flushes++;
}

class _FullBackend extends FakeFullUpdates {
  VpnController? vpn;
  _Appearance? appearance;
  bool reservedAtHandoff = false;
  bool flushedAtHandoff = false;

  @override
  Future<void> restartUi() async {
    reservedAtHandoff = vpn!.applicationRestartPending;
    flushedAtHandoff = appearance!.flushes > 0;
    await super.restartUi();
  }

  @override
  Future<FullUpdateHandoff> handoff(FullUpdateOffer selected) {
    reservedAtHandoff = vpn!.applicationRestartPending;
    flushedAtHandoff = appearance!.flushes > 0;
    return super.handoff(selected);
  }
}

Future<({VpnController vpn, _FullBackend backend, FakeBridge bridge})> _open(
  WidgetTester tester, {
  bool connected = false,
  Object? handoffError,
  Completer<FullUpdateHandoff>? handoff,
  FakePatchUpdates? patch,
  Object? restartError,
}) async {
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = FakeBridge()..current = connected ? running() : off;
  final vpn = VpnController(bridge);
  final appearance = _Appearance();
  final backend = _FullBackend()
    ..handoffResult = FullUpdateHandoff.installerOpened
    ..handoffError = handoffError
    ..pendingHandoff = handoff
    ..restartError = restartError
    ..vpn = vpn
    ..appearance = appearance;
  final dart = DartUpdatesController(
    backend: patch ?? const DisabledDartUpdatesBackend(),
  );
  if (patch != null) backend.available = null;
  await tester.pumpWidget(
    ExVpnApp(
      controller: AppController(),
      vpn: vpn,
      fullUpdatesBackend: backend,
      appearanceController: appearance,
      dartUpdates: dart,
      updates: DataUpdatesController(
        vpn: vpn,
        backend: DisabledDataUpdatesBackend(),
      ),
    ),
  );
  // An accepted native replacement keeps its progress animation until this
  // process exits; the fake deliberately does not terminate the test runner.
  if (patch != null && !connected && restartError == null) {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  } else {
    await tester.pumpAndSettle();
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await bridge.close();
  });
  return (vpn: vpn, backend: backend, bridge: bridge);
}

AppUpdatesController _updates(WidgetTester tester) =>
    tester.widget<AppUpdatesScope>(find.byType(AppUpdatesScope)).notifier!;

void _androidWidgets(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

void main() {
  _androidWidgets(
    'Android installer handoff flushes, reserves then releases UI without exiting',
    (tester) async {
      var nativeExitCalls = 0;
      const tray = MethodChannel('exvpn/tray');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(tray, (
        call,
      ) async {
        if (call.method == 'exit') nativeExitCalls++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          tray,
          null,
        ),
      );
      final handoff = Completer<FullUpdateHandoff>();
      final state = await _open(tester, handoff: handoff);
      final updates = _updates(tester);
      expect(updates.phase, AppUpdateStatePhase.available);
      final operation = updates.download();
      await tester.pump();
      await tester.pump();
      expect(state.backend.handoffs, 1);
      expect(state.backend.reservedAtHandoff, isTrue);
      expect(state.backend.flushedAtHandoff, isTrue);
      expect(state.vpn.applicationRestartPending, isTrue);
      handoff.complete(FullUpdateHandoff.installerOpened);
      await operation;
      await tester.pumpAndSettle();
      expect(updates.phase, AppUpdateStatePhase.restartReady);
      expect(updates.canRestart, isTrue);
      expect(updates.busy, isFalse);
      expect(state.vpn.applicationRestartPending, isFalse);
      expect(state.vpn.canChangeConnection, isTrue);
      expect(nativeExitCalls, 0);
      expect(state.bridge.disconnects, 0);
      expect(find.text('Установить обновление'), findsOneWidget);
      expect(tester.getSize(find.byType(AppUpdateStrip)), const Size(420, 24));
      expect(find.text('Обновление готово — перезапустить'), findsNothing);
      expect(
        find.text('Обновление применится при следующем запуске'),
        findsNothing,
      );
      expect(
        tester.widget<AppUpdateStrip>(find.byType(AppUpdateStrip)).state.phase,
        AppUpdatePhase.ready,
      );
      await updates.restart();
      expect(state.backend.handoffs, 2);
      expect(state.backend.downloads, 1);
      expect(state.vpn.applicationRestartPending, isFalse);
    },
  );

  _androidWidgets(
    'Android active VPN blocks install without disconnecting it',
    (tester) async {
      final state = await _open(tester, connected: true);
      final updates = _updates(tester);
      await updates.download();
      await tester.pump();
      expect(updates.phase, AppUpdateStatePhase.blocked);
      expect(state.backend.handoffs, 0);
      expect(state.bridge.disconnects, 0);
      expect(state.vpn.status.phase, running().phase);
      expect(state.vpn.applicationRestartPending, isFalse);
      expect(find.text('Для установки отключите VPN'), findsOneWidget);
      state.bridge.emit(off);
      await updates.retry();
      await tester.pump();
      expect(state.backend.handoffs, 1);
      expect(updates.phase, AppUpdateStatePhase.restartReady);
      expect(state.backend.downloads, 1);
    },
  );

  for (final entry in {
    'install_permission_required': 'Разрешите установку обновлений',
    'install_cancelled': 'Установка отменена — повторить',
    'install_failed': 'Не удалось установить — повторить',
  }.entries) {
    _androidWidgets(
      'Android ${entry.key} offers a short retry and releases VPN commands',
      (tester) async {
        final state = await _open(
          tester,
          handoffError: AppUpdatesFailure(entry.key),
        );
        final updates = _updates(tester);
        await updates.download();
        await tester.pump();
        expect(updates.phase, AppUpdateStatePhase.failed);
        expect(updates.errorCode, entry.key);
        expect(find.text(entry.value), findsOneWidget);
        expect(state.vpn.applicationRestartPending, isFalse);
        expect(state.vpn.canChangeConnection, isTrue);
        expect(state.bridge.disconnects, 0);
        state.backend.handoffError = null;
        await updates.retry();
        await tester.pump();
        expect(updates.phase, AppUpdateStatePhase.restartReady);
        expect(state.backend.downloads, 1);
        expect(state.backend.handoffs, 2);
      },
    );
  }

  _androidWidgets(
    'Android staged patch automatically cold restarts after flush without tray exit',
    (tester) async {
      final patch = FakePatchUpdates()
        ..saved = const DartPatchSnapshot(available: true, next: 2);
      final state = await _open(tester, patch: patch);
      expect(state.backend.restarts, 1);
      expect(state.backend.reservedAtHandoff, isTrue);
      expect(state.backend.flushedAtHandoff, isTrue);
      expect(state.vpn.applicationRestartPending, isTrue);
      expect(state.bridge.disconnects, 0);
      expect(patch.downloads, 0);
      await _updates(tester).onResume();
      expect(state.backend.restarts, 1);
    },
  );

  _androidWidgets(
    'Android active VPN defers patch then automatically restarts after normal disconnect',
    (tester) async {
      final patch = FakePatchUpdates()
        ..saved = const DartPatchSnapshot(available: true, next: 2);
      final state = await _open(tester, patch: patch, connected: true);
      expect(state.backend.restarts, 0);
      expect(state.bridge.disconnects, 0);
      expect(state.vpn.applicationRestartPending, isFalse);
      state.bridge.emit(off);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(state.backend.restarts, 1);
      expect(state.bridge.disconnects, 0);
      expect(patch.downloads, 0);
    },
  );

  _androidWidgets(
    'native restart failure releases commands without reservation notification retry loop',
    (tester) async {
      final patch = FakePatchUpdates()
        ..saved = const DartPatchSnapshot(available: true, next: 2);
      final state = await _open(
        tester,
        patch: patch,
        restartError: AppUpdatesFailure('handoff_failed'),
      );
      expect(state.backend.restarts, 1);
      expect(state.vpn.applicationRestartPending, isFalse);
      for (var i = 0; i < 3; i++) {
        state.bridge.emit(off);
        await tester.pumpAndSettle();
      }
      await _updates(tester).onResume();
      expect(state.backend.restarts, 1);
    },
  );
}
