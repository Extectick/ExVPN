import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/subscription_edit_dialog.dart';
import 'package:exvpn/src/theme.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

Widget screen(AppController app) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  supportedLocales: const [Locale('ru')],
  theme: exVpnTheme(Brightness.light),
  home: HomeScreen(
    controller: app,
    latencyProbe: (_) async =>
        const ProbeResult(reachable: true, latency: Duration(milliseconds: 30)),
    themeMode: ThemeMode.light,
    onThemeChanged: (_) {},
  ),
);
Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unsupported rows show an overlay and cannot select or probe', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(426, 922);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppController();
    app.addSubscription(
      raw:
          'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Working\n'
          'tuic://synthetic-secret@private.invalid:443#🇯🇵%20Tokyo',
    );
    final probed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('ru')],
        theme: exVpnTheme(Brightness.light),
        home: HomeScreen(
          controller: app,
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          latencyProbe: (profile) async {
            probed.add(profile.server);
            return const ProbeResult(
              reachable: true,
              latency: Duration(milliseconds: 30),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('Не поддерживается'), findsOneWidget);
    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('TUIC'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subscription-issues-subscription-1')),
      findsNothing,
    );
    final selected = app.selectedServerId;
    await tester.tap(
      find.byKey(const ValueKey('unsupported-subscription-1-2')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(app.selectedServerId, selected);
    await tap(tester, find.byKey(const Key('ping-all-button')));
    expect(probed, isNotEmpty);
    expect(probed.toSet(), {'sample.invalid'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets(
    'demo profiles never start real endpoint probes without an injected simulator',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(426, 922);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final vpn = VpnController(bridge);
      final app = AppController.demo();
      await vpn.initialize();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('ru')],
          home: HomeScreen(
            controller: app,
            vpn: vpn,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('42 мс'), findsOneWidget);
      expect(find.text('58 мс'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      vpn.dispose();
      await bridge.close();
    },
  );

  testWidgets(
    'group menu replaces count, edits only its own name and does not collapse',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(426, 922);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AppController.demo();
      await tester.pumpWidget(screen(app));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('4 подключения'), findsNothing);
      expect(find.text('2 подключения'), findsNothing);
      await tap(
        tester,
        find.byKey(const ValueKey('subscription-menu-demo-main')),
      );
      expect(app.groups.first.expanded, true);
      await tap(tester, find.text('Редактировать'));
      expect(find.byType(SubscriptionEditDialog), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('edit-subscription-name')),
            )
            .controller!
            .text,
        'Основная подписка',
      );
      await tester.enterText(
        find.byKey(const Key('edit-subscription-name')),
        'Моя подписка',
      );
      await tap(tester, find.byKey(const Key('edit-subscription-save')));
      expect(app.groups.first.name, 'Моя подписка');
      expect(app.groups.last.name, 'Резервная подписка');
      expect(app.groups.first.servers.length, 4);
      expect(app.selectedServerId, app.groups.first.servers.first.id);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'delete requires confirmation and cancel preserves the exact group',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = const Size(426, 922);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AppController.demo();
      await tester.pumpWidget(screen(app));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      Future<void> chooseDelete() async {
        await tap(
          tester,
          find.byKey(const ValueKey('subscription-menu-demo-main')),
        );
        await tap(tester, find.text('Удалить'));
        expect(find.text('Удалить подписку?'), findsOneWidget);
      }

      await chooseDelete();
      await tap(tester, find.text('Отмена'));
      expect(app.groups.length, 2);
      await chooseDelete();
      await tap(tester, find.text('Удалить'));
      expect(app.groups.single.id, 'demo-backup');
      expect(
        find.byKey(const ValueKey('subscription-menu-demo-main')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'editor preloads HTTPS; invalid URL leaves working subscription intact',
    (tester) async {
      final app = AppController()
        ..addSubscription(
          name: 'Existing',
          raw: 'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Node',
          sourceUrl: 'https://sample.invalid/old',
        );
      final group = app.groups.single;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('ru')],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      SubscriptionEditDialog(controller: app, group: group),
                ),
                child: const Text('Edit'),
              ),
            ),
          ),
        ),
      );
      await tap(tester, find.text('Edit'));
      final source = find.byKey(const Key('edit-subscription-source'));
      expect(
        tester.widget<TextFormField>(source).controller!.text,
        'https://sample.invalid/old',
      );
      await tester.enterText(source, 'http://sample.invalid/new');
      await tap(tester, find.byKey(const Key('edit-subscription-save')));
      expect(find.text('Укажите ссылку HTTPS'), findsOneWidget);
      expect(app.groups.single.sourceUrl, group.sourceUrl);
      await tester.enterText(source, 'https://sample.invalid/new');
      await tap(tester, find.byKey(const Key('edit-subscription-save')));
      expect(app.groups.single.sourceUrl, 'https://sample.invalid/new');
      expect(app.groups.single.servers.single.name, 'Node');
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );

  testWidgets(
    'automatic ping is viewport-only, cached on reshow and inactive in background',
    (tester) async {
      tester.view.physicalSize = const Size(426, 922);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final app = AppController()
        ..addSubscription(
          name: 'Visible',
          raw: [
            for (var i = 0; i < 25; i++)
              'vless://00000000-0000-4000-8000-000000000001@n$i.example.invalid:443?security=tls#Node$i',
          ].join('\n'),
        );
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            controller: app,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
            latencyProbe: (profile) async {
              calls.add(profile.id);
              return const ProbeResult(
                reachable: true,
                latency: Duration(milliseconds: 30),
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(calls.length, greaterThan(0));
      expect(calls.length, lessThan(25));
      final count = calls.length;
      await tester.drag(
        find.byKey(const PageStorageKey('servers-medium')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(calls.length, greaterThan(count));
      final afterScroll = calls.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 6));
      expect(calls.length, afterScroll);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    },
  );
}
