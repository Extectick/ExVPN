// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:exvpn/main.dart';
import 'package:exvpn/build_identity.dart';
import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/updates_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data_updates_test.dart' show FakeUpdates;
import 'vpn_controller_test.dart' show FakeBridge, running, off;

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find.byType(Scrollable).last,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Widget _russianUpdates(Widget home) => MaterialApp(
  locale: const Locale('ru'),
  supportedLocales: const [Locale('ru')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: home,
);

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
        _russianUpdates(UpdatesSheet(updates: controller)),
      );
      expect(find.text('ExVPN $appVersion'), findsOneWidget);
      expect(find.byKey(const Key('updates-check')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('updates-disabled')),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Обновления справки пока недоступны.'), findsOneWidget);
      expect(find.textContaining('доверенного адреса'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byKey(const Key('updates-diagnostics')), findsNothing);
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
    await tester.pumpWidget(_russianUpdates(UpdatesSheet(updates: controller)));
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
    expect(controller.snapshot.revision, 2);
    expect(find.text('Ревизия 2'), findsNothing);
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
      final dart = DartUpdatesController(
        backend: const DisabledDartUpdatesBackend(),
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
          updates: updates,
          dartUpdates: dart,
          appUpdates: appUpdates,
        ),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('settings-button')));
      await tapVisible(tester, find.text('Версии и обновления'));
      expect(find.text('Ревизия 4'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('Dart-патч'), findsNothing);
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
      await tapVisible(tester, find.byType(BackButton));
      await tapVisible(tester, find.text('Обезличенная диагностика'));
      final report = jsonDecode(
        tester.widget<SelectableText>(find.byType(SelectableText)).data!,
      ) as Map<String, dynamic>;
      expect((report['updates'] as Map)['dataRevision'], 4);
      expect((report['updates'] as Map)['dartAvailable'], false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
