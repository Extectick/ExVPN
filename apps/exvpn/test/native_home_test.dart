import 'dart:async';

import 'package:exvpn/main.dart';
import 'package:exvpn/src/power_button.dart';
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/app_strings.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge, ModeBridge;

Future<({AppController app, VpnController vpn})> openConnectionControls(
  WidgetTester tester,
  ModeBridge bridge,
) async {
  await tester.binding.setSurfaceSize(const Size(440, 760));
  final app = AppController()
    ..addSubscription(
      name: 'Test',
      raw: [
        for (var i = 1; i <= 3; i++)
          'vless://00000000-0000-4000-8000-00000000000$i@sample$i.invalid:443?security=tls#Server$i',
      ].join('\n'),
    );
  final vpn = VpnController(bridge);
  await vpn.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    vpn.dispose();
    app.dispose();
    await bridge.close();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: appSupportedLocales,
      localeListResolutionCallback: resolveAppLocale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomeScreen(
        controller: app,
        vpn: vpn,
        themeMode: ThemeMode.dark,
        onThemeChanged: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (app: app, vpn: vpn);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localesTestValue =
        const [Locale('ru')];
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocalesTestValue();
  });
  testWidgets('cold UI waits for native status before offering connect', (
    tester,
  ) async {
    final snapshot = Completer<VpnStatus>();
    final bridge = FakeBridge()..snapshot = snapshot.future;
    await tester.pumpWidget(
      ExVpnApp(controller: AppController.demo(), vpn: VpnController(bridge)),
    );
    await tester.pump();
    expect(
      tester
          .widget<PowerButton>(find.byKey(const Key('connect-button')))
          .enabled,
      isFalse,
    );
    expect(
      tester.widget<PowerButton>(find.byKey(const Key('connect-button'))).label,
      'Проверка состояния VPN',
    );
    expect(find.text('Не подключено'), findsNothing);
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(bridge.connects, 0);
    expect(find.text('VPN пока недоступен'), findsNothing);
    snapshot.complete(
      const VpnStatus(
        phase: VpnPhase.blocked,
        processCrashProtection: true,
        errorCode: 'native_storage_unavailable',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<PowerButton>(find.byKey(const Key('connect-button'))).label,
      'Отключить VPN',
    );
    await tester.tap(find.byKey(const Key('connection-notice')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Трафик заблокирован'), findsOneWidget);
    expect(
      find.text('Не удалось открыть защищённые настройки VPN.'),
      findsOneWidget,
    );
    expect(find.textContaining('Код:'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await bridge.close();
  });

  testWidgets(
    'native connect uses selected profile and authoritative status drives disconnect',
    (tester) async {
      final bridge = FakeBridge();
      final vpn = VpnController(bridge);
      final app = AppController()
        ..addSubscription(
          name: 'Test',
          raw: 'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
        );
      await tester.pumpWidget(ExVpnApp(controller: app, vpn: vpn));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(bridge.connects, 1);
      expect(find.text('VPN пока недоступен'), findsNothing);
      expect(find.textContaining('Подключено ·'), findsNothing);
      bridge.emit(
        VpnStatus(
          phase: VpnPhase.connected,
          processCrashProtection: false,
          activeProfileId: app.selectedServer!.profile.id,
          connectedAt: DateTime.now(),
        ),
      );
      await tester.pumpAndSettle();
      final power = tester.widget<PowerButton>(
        find.byKey(const Key('connect-button')),
      );
      expect(power.label, 'Отключить VPN');
      expect(power.active, isTrue);
      expect(power.elapsedLabel, matches(RegExp(r'^\d{2}:\d{2}:\d{2}$')));
      expect(find.textContaining('Подключено ·'), findsNothing);
      expect(
        find.text('Защита при сбое процесса не подтверждена'),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(bridge.disconnects, 1);
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .active,
        isFalse,
      );
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .label,
        'Подключить VPN',
      );
      await tester.pumpWidget(const SizedBox());
      await bridge.close();
    },
  );

  testWidgets('demo profiles cannot reach native connect', (tester) async {
    final bridge = FakeBridge();
    await tester.pumpWidget(
      ExVpnApp(controller: AppController.demo(), vpn: VpnController(bridge)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(bridge.connects, 0);
    expect(find.text('VPN пока недоступен'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await bridge.close();
  });

  testWidgets(
    'connecting controls coalesce server and mode choices without an intermediate disconnect',
    (tester) async {
      final initial = Completer<void>();
      final latest = Completer<void>();
      final bridge = ModeBridge()
        ..connectResult = initial.future
        ..reconnectResult = latest.future;
      final state = await openConnectionControls(tester, bridge);
      final servers = state.app.groups.single.servers;
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pump();
      bridge.emit(
        VpnStatus(
          phase: VpnPhase.connecting,
          processCrashProtection: false,
          systemProxySupported: true,
          activeProfileId: servers.first.profile.id,
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .enabled,
        isTrue,
      );
      for (final server in servers.skip(1)) {
        final row = find.byKey(
          ValueKey('server-${state.app.groups.single.id}-${server.id}'),
        );
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pump();
      }
      await tester.tap(find.text('PROXY'));
      await tester.pump();
      expect(state.vpn.desiredProfileId, servers.last.profile.id);
      expect(state.vpn.mode, VpnMode.proxy);
      expect(bridge.modeConnects, [(servers.first.profile.id, VpnMode.vpn)]);
      expect(bridge.reconfigurations, isEmpty);
      expect(bridge.disconnects, 0);
      initial.complete();
      await tester.pump();
      await tester.pump();
      expect(bridge.reconfigurations, [
        (servers.last.profile.id, VpnMode.proxy),
      ]);
      bridge.emit(
        VpnStatus(
          phase: VpnPhase.connecting,
          processCrashProtection: false,
          systemProxySupported: true,
          activeProfileId: servers.last.profile.id,
          mode: VpnMode.proxy,
        ),
      );
      latest.complete();
      await tester.pump();
      await tester.pump();
      expect(state.app.selectedServer!.id, servers.last.id);
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .active,
        isFalse,
      );
      bridge.active(servers.last.profile, mode: VpnMode.proxy);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .active,
        isTrue,
      );
      expect(bridge.disconnects, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'power cancels connecting and queued selections without a late reconnect',
    (tester) async {
      final initial = Completer<void>();
      final stopped = Completer<void>();
      final bridge = ModeBridge()
        ..connectResult = initial.future
        ..disconnectResult = stopped.future;
      final state = await openConnectionControls(tester, bridge);
      final servers = state.app.groups.single.servers;
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pump();
      bridge.emit(
        VpnStatus(
          phase: VpnPhase.connecting,
          processCrashProtection: false,
          systemProxySupported: true,
          activeProfileId: servers.first.profile.id,
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          ValueKey('server-${state.app.groups.single.id}-${servers.last.id}'),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pump();
      expect(bridge.disconnects, 1);
      expect(
        tester
            .widget<PowerButton>(find.byKey(const Key('connect-button')))
            .enabled,
        isFalse,
      );
      stopped.complete();
      initial.complete();
      await tester.pumpAndSettle();
      expect(bridge.reconfigurations, isEmpty);
      expect(state.app.selectedServer!.id, servers.first.id);
      expect(state.vpn.status.phase, VpnPhase.disconnected);
      final power = tester.widget<PowerButton>(
        find.byKey(const Key('connect-button')),
      );
      expect(power.active, isFalse);
      expect(power.connecting, isFalse);
      expect(power.enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
