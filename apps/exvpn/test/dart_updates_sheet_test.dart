// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn/main.dart';
import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/updates_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'dart_updates_test.dart' show FakeDartUpdates;
import 'updates_sheet_test.dart' show tapVisible;
import 'vpn_controller_test.dart' show FakeBridge, running;

Widget _russianUpdates(UpdatesSheet home) {
  final appUpdates = AppUpdatesController(
    fullBackend: const DisabledFullUpdatesBackend(),
    dartUpdates: home.dartUpdates,
  );
  addTearDown(appUpdates.dispose);
  return MaterialApp(
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: AppUpdatesScope(controller: appUpdates, child: home),
  );
}

void main() {
  testWidgets(
    'unavailable engine does not display a base patch or offer a download',
    (tester) async {
      final data = DataUpdatesController(
        vpn: null,
        backend: DisabledDataUpdatesBackend(),
      );
      final dart = DartUpdatesController(
        backend: const DisabledDartUpdatesBackend(),
      );
      addTearDown(data.dispose);
      addTearDown(dart.dispose);
      await dart.initialize();
      await tester.pumpWidget(
        _russianUpdates(UpdatesSheet(updates: data, dartUpdates: dart)),
      );
      expect(find.text('Недоступен в этой сборке'), findsNothing);
      expect(find.text('Базовый выпуск'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('updates-primary')), findsOneWidget);
      expect(find.byKey(const Key('dart-updates-check')), findsNothing);
      expect(find.byKey(const Key('dart-updates-download')), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'startup checks once; opening versions and patch download leave active VPN alone',
    (tester) async {
      final bridge = FakeBridge();
      final vpn = VpnController(bridge);
      final backend = FakeDartUpdates()
        ..saved = const DartPatchSnapshot(available: true, current: 7, next: 7);
      final dart = DartUpdatesController(backend: backend);
      final data = DataUpdatesController(
        vpn: vpn,
        backend: DisabledDataUpdatesBackend(),
      );
      final appUpdates = AppUpdatesController(
        fullBackend: const DisabledFullUpdatesBackend(),
        dartUpdates: dart,
      );
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(
        ExVpnApp(
          controller: AppController(),
          vpn: vpn,
          updates: data,
          dartUpdates: dart,
          appUpdates: appUpdates,
        ),
      );
      await tester.pumpAndSettle();
      bridge.emit(running());
      await tester.pump();
      expect(backend.reads, 1);
      expect(backend.checks, 1);
      await tapVisible(tester, find.byKey(const Key('settings-button')));
      await tapVisible(tester, find.text('Версии и обновления'));
      expect(backend.reads, 1);
      expect(backend.checks, 2);
      expect(find.text('Патч 7'), findsNothing);
      expect(dart.snapshot!.current, 7);
      backend.saved = const DartPatchSnapshot(
        available: true,
        current: 7,
        next: 8,
      );
      await tapVisible(tester, find.byKey(const Key('updates-primary')));
      expect(find.text('Установить и перезапустить'), findsOneWidget);
      expect(dart.snapshot!.current, 7);
      expect(backend.downloads, 1);
      expect(bridge.disconnects, 0);
      expect(bridge.connects, 0);
      expect(vpn.status.phase, running().phase);
      expect(find.byKey(const Key('dart-updates-download')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await bridge.close();
    },
  );

  testWidgets(
    'rollback to base is distinct from active patch on narrow large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final data = DataUpdatesController(
        vpn: null,
        backend: DisabledDataUpdatesBackend(),
      );
      final backend = FakeDartUpdates()
        ..saved = const DartPatchSnapshot(available: true, current: 4)
        ..nextStatus = DartUpdateStatus.restartRequired;
      final dart = DartUpdatesController(backend: backend);
      addTearDown(data.dispose);
      addTearDown(dart.dispose);
      await dart.initialize();
      await tester.pumpWidget(
        _russianUpdates(UpdatesSheet(updates: data, dartUpdates: dart)),
      );
      expect(find.text('Патч 4'), findsNothing);
      expect(dart.snapshot!.current, 4);
      await tester.pumpAndSettle();
      expect(find.text('Установить и перезапустить'), findsOneWidget);
      expect(dart.snapshot!.next, isNull);
      expect(find.byKey(const Key('dart-updates-download')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('metadata failure is visible and offers a local retry', (
    tester,
  ) async {
    final data = DataUpdatesController(
      vpn: null,
      backend: DisabledDataUpdatesBackend(),
    );
    final backend = FakeDartUpdates()
      ..readError = StateError('private token and response');
    final dart = DartUpdatesController(backend: backend);
    addTearDown(data.dispose);
    addTearDown(dart.dispose);
    await dart.initialize();
    await tester.pumpWidget(
      _russianUpdates(UpdatesSheet(updates: data, dartUpdates: dart)),
    );
    expect(find.text('Не удалось определить'), findsOneWidget);
    expect(find.text('Dart-патч'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.text('Базовый выпуск'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('updates-error')), findsOneWidget);
    expect(find.textContaining('private token'), findsNothing);
    backend.readError = null;
    await tapVisible(tester, find.byKey(const Key('updates-primary')));
    expect(dart.snapshot!.available, true);
    expect(dart.snapshot!.current, isNull);
    expect(backend.checks, 1);
    expect(tester.takeException(), isNull);
  });
}
