import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/power_button.dart';
import 'package:exvpn/src/settings_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_home_test.dart' show openConnectionControls;
import 'vpn_controller_test.dart' show ModeBridge, off;

class _RejectedConsentBridge extends ModeBridge {
  _RejectedConsentBridge(this.code);
  final String code;

  @override
  Future<void> connectInMode(ConnectionProfile profile, VpnMode mode) async {
    modeConnects.add((profile.id, mode));
    emit(
      VpnStatus(
        phase: VpnPhase.requestingPermission,
        activeProfileId: profile.id,
        processCrashProtection: false,
        systemProxySupported: true,
      ),
    );
    emit(
      VpnStatus(
        phase: VpnPhase.disconnected,
        errorCode: code,
        processCrashProtection: false,
        systemProxySupported: true,
      ),
    );
    throw VpnFailure(code);
  }
}

void main() {
  for (final code in ['permission_denied', 'vpn_permission_unavailable']) {
    testWidgets('$code remains red and retries without an idle disconnect', (
      tester,
    ) async {
      final bridge = _RejectedConsentBridge(code);
      final state = await openConnectionControls(tester, bridge);
      final buttonFinder = find.byKey(const Key('connect-button'));
      final connectLabel = tester.widget<PowerButton>(buttonFinder).label;
      for (var attempt = 1; attempt <= 2; attempt++) {
        await tester.tap(buttonFinder);
        await tester.pumpAndSettle();
        expect(bridge.modeConnects.length, attempt);
        expect(bridge.disconnects, 0);
        expect(state.vpn.status.phase, VpnPhase.disconnected);
        expect(state.vpn.canDisconnect, isFalse);
        expect(state.vpn.lastErrorCode, code);
        final button = tester.widget<PowerButton>(buttonFinder);
        expect(button.failed, isTrue);
        expect(button.connecting, isFalse);
        expect(button.label, connectLabel);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('settings dismisses when pulled down from its contents', (
    tester,
  ) async {
    final app = AppController.demo();
    addTearDown(app.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: HomeScreen(
          controller: app,
          themeMode: ThemeMode.dark,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byType(SettingsSheet)) + const Offset(120, 180),
    );
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 36));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final phase in [VpnPhase.blocked, VpnPhase.error]) {
    testWidgets(
      '$phase is visibly failed without silently removing protection',
      (tester) async {
        final bridge = ModeBridge()
          ..current = VpnStatus(
            phase: phase,
            processCrashProtection: false,
            errorCode: 'tunnel_unreachable',
          );
        await openConnectionControls(tester, bridge);
        PowerButton button() =>
            tester.widget<PowerButton>(find.byKey(const Key('connect-button')));
        expect(button().failed, isTrue);
        expect(button().active, isFalse);
        expect(button().connecting, isFalse);
        expect(button().enabled, isTrue);
        expect(bridge.disconnects, 0);
        if (phase == VpnPhase.blocked) {
          await tester.tap(find.byKey(const Key('connect-button')));
          await tester.pumpAndSettle();
          expect(bridge.disconnects, 1);
        } else {
          bridge.emit(off);
          await tester.pumpAndSettle();
        }
        expect(button().failed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed subscription refresh keeps the list without a retry strip',
    (tester) async {
      final app = AppController.demo();
      addTearDown(app.dispose);
      var refreshCalls = 0;
      var refreshFails = true;
      await tester.binding.setSurfaceSize(const Size(440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: HomeScreen(
            controller: app,
            themeMode: ThemeMode.dark,
            onThemeChanged: (_) {},
            previewRefreshAction: () async {
              refreshCalls++;
              return refreshFails ? [app.groups.first.id] : [];
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(
        ValueKey(
          'server-${app.groups.first.id}-${app.groups.first.servers.first.id}',
        ),
      );
      final before = tester.getRect(row);
      final selected = app.selectedServerId;
      await tester.tap(find.byKey(const Key('refresh-button')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('retry-subscription-${app.groups.first.id}')),
        findsNothing,
      );
      expect(find.text('Не удалось обновить подписку'), findsNothing);
      final issues = find.byKey(
        ValueKey('subscription-issues-${app.groups.first.id}'),
      );
      expect(issues, findsOneWidget);
      expect(tester.getRect(row), before);
      expect(app.groups.first.servers, isNotEmpty);
      expect(app.selectedServerId, selected);
      expect(refreshCalls, 1);
      await tester.tap(issues);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Нет соединения с сервером подписки. Последний список сохранён.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      refreshFails = false;
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 2);
      expect(issues, findsNothing);
      expect(find.byKey(const Key('subscription-issues-dialog')), findsNothing);
      expect(tester.getRect(row), before);
      expect(app.selectedServerId, selected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'permission errors describe refusal and unavailable dialogs truthfully',
    () {
      expect(
        vpnErrorText('permission_denied'),
        isNot(contains('Разрешите VPN в системном запросе')),
      );
      expect(
        vpnErrorText('vpn_permission_unavailable'),
        allOf(
          contains('Android не открыл запрос VPN'),
          contains('настройки VPN'),
        ),
      );
    },
  );
}
