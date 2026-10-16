import 'dart:async';

import 'package:exvpn/main.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

void main() {
  testWidgets('cold UI waits for native status before offering connect', (
    tester,
  ) async {
    final snapshot = Completer<VpnStatus>();
    final bridge = FakeBridge()..snapshot = snapshot.future;
    await tester.pumpWidget(
      ExVpnApp(controller: AppController.demo(), vpn: VpnController(bridge)),
    );
    await tester.pump();
    expect(find.text('Проверка состояния VPN…'), findsOneWidget);
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
    expect(find.text('Трафик заблокирован'), findsOneWidget);
    expect(find.text('Отключить'), findsOneWidget);
    expect(
      find.textContaining('Код: native_storage_unavailable'),
      findsOneWidget,
    );
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
      expect(find.text('Отключить'), findsOneWidget);
      expect(find.textContaining('Подключено ·'), findsOneWidget);
      expect(
        find.text('Защита при сбое процесса не подтверждена'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(bridge.disconnects, 1);
      expect(find.text('Не подключено'), findsOneWidget);
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
}
