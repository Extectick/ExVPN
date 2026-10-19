// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:exvpn/build_identity.dart';
import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/src/updates_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_updates_test.dart' show FakeFullUpdates, offer;

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

void main() {
  late FakeFullUpdates backend;
  late DartUpdatesController dart;
  late AppUpdatesController app;
  late DataUpdatesController data;
  setUp(() {
    backend = FakeFullUpdates();
    dart = DartUpdatesController(backend: const DisabledDartUpdatesBackend());
    app = AppUpdatesController(
      fullBackend: backend,
      dartUpdates: dart,
      beforeRestart: (_, handoff) async {
        await handoff();
        return true;
      },
    );
    data = DataUpdatesController(
      vpn: null,
      backend: DisabledDataUpdatesBackend(),
    );
  });
  tearDown(() {
    app.dispose();
    dart.dispose();
    data.dispose();
  });
  Widget screen() => MaterialApp(
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: AppUpdatesScope(
      controller: app,
      child: UpdatesSheet(updates: data),
    ),
  );

  testWidgets(
    'auto check once, repeat with same full-width button, only two versions',
    (tester) async {
      backend.available = null;
      tester.view.physicalSize = const Size(320, 440);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(backend.checks, 1);
      expect(find.text('Проверить'), findsOneWidget);
      expect(find.text('ExVPN $appVersion'), findsOneWidget);
      expect(find.text('Ядро'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('updates-primary'))).width,
        280,
      );
      expect(find.textContaining('справк'), findsNothing);
      expect(find.text('Обновления интерфейса'), findsNothing);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(backend.checks, 1);
      await tester.tap(find.byKey(const Key('updates-primary')));
      await tester.pumpAndSettle();
      expect(backend.checks, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download progress prevents double command, then automatic install and restart',
    (tester) async {
      backend.pendingDownload = Completer<FullUpdateOffer>();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('Скачать и установить'), findsOneWidget);
      await tester.tap(find.byKey(const Key('updates-primary')));
      await tester.pump();
      backend.progress!(const FullUpdateProgress(received: 50, total: 100));
      await tester.pump();
      expect(find.text('Загружаем обновление… 50%'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('updates-primary')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('updates-primary')));
      expect(backend.downloads, 1);
      backend.pendingDownload!.complete(offer);
      await tester.pump();
      await tester.pump();
      expect(backend.handoffs, 1);
      expect(app.phase, AppUpdateStatePhase.restarting);
      expect(find.text('Установка и перезапуск…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one short failure and retry; opening during a running check shares it',
    (tester) async {
      backend.pendingCheck = Completer<FullUpdateOffer?>();
      final checking = app.check();
      await tester.pumpWidget(screen());
      await tester.pump();
      expect(backend.checks, 1);
      expect(find.text('Проверяем обновления…'), findsOneWidget);
      backend.pendingCheck!.completeError(AppUpdatesFailure('network_failed'));
      await checking;
      await tester.pumpAndSettle();
      expect(find.text('Не удалось проверить обновления.'), findsOneWidget);
      expect(find.textContaining('network_failed'), findsNothing);
      backend.pendingCheck = null;
      await tester.tap(find.byKey(const Key('updates-primary')));
      await tester.pumpAndSettle();
      expect(backend.checks, 2);
      expect(find.text('Скачать и установить'), findsOneWidget);
      expect(find.byKey(const Key('updates-error')), findsNothing);
    },
  );

  testWidgets(
    'navigation permits restart only on read-only updates route, not another dialog',
    (tester) async {
      final observer = UpdatesNavigationObserver();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [observer],
          home: const SizedBox(),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: UpdatesSheet.routeName),
            builder: (_) => const Scaffold(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.showingUpdates, true);
      unawaited(
        showDialog<void>(
          context: navigator.currentState!.overlay!.context,
          builder: (_) => const AlertDialog(content: Text('Unsaved form')),
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.showingUpdates, false);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(observer.showingUpdates, true);
    },
  );
}
