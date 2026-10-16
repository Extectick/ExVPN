// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn/main.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/updates_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'data_updates_test.dart' show FakeUpdates;
import 'vpn_controller_test.dart' show FakeBridge, running, off;

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    250,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'default disabled screen shows real versions and no check action at narrow scale',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = DataUpdatesController(
        vpn: null,
        backend: DisabledDataUpdatesBackend(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(home: UpdatesSheet(updates: controller)),
      );
      expect(find.text('ExVPN 0.1.0'), findsOneWidget);
      expect(find.byKey(const Key('updates-check')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('updates-disabled')),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('нет доверенного адреса и ключа'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('active VPN disables apply; cancel and later safe apply work', (
    tester,
  ) async {
    final bridge = FakeBridge();
    final vpn = VpnController(bridge);
    final backend = FakeUpdates();
    final controller = DataUpdatesController(vpn: vpn, backend: backend);
    addTearDown(() async {
      controller.dispose();
      vpn.dispose();
      await bridge.close();
    });
    await vpn.initialize();
    bridge.emit(running());
    await controller.initialize();
    await controller.check();
    await tester.pumpWidget(
      MaterialApp(home: UpdatesSheet(updates: controller)),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('updates-apply')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('updates-apply')))
          .onPressed,
      isNull,
    );
    await tapVisible(tester, find.byKey(const Key('updates-cancel')));
    expect(backend.cancelled, 1);
    expect(backend.applied, 0);
    expect(bridge.disconnects, 0);
    bridge.emit(off);
    await tapVisible(tester, find.byKey(const Key('updates-check')));
    await tapVisible(tester, find.byKey(const Key('updates-apply')));
    expect(backend.applied, 1);
    await tapVisible(tester, find.byKey(const Key('updates-recover')));
    await tester.scrollUntilVisible(
      find.text('Ревизия 2'),
      -250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Ревизия 2'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('updates-help')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Проверенная новая справка.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'application settings open versions screen through lifetime scope',
    (tester) async {
      final backend = FakeUpdates()
        ..current = const DataUpdateSnapshot(
          revision: 4,
          help: 'Сохранённая проверенная справка для подключения.',
        );
      final updates = DataUpdatesController(vpn: null, backend: backend);
      await tester.pumpWidget(
        ExVpnApp(controller: AppController(), updates: updates),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('settings-button')));
      await tapVisible(tester, find.text('Версии и обновления'));
      expect(find.text('Ревизия 4'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('updates-help')),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Сохранённая проверенная справка для подключения.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
