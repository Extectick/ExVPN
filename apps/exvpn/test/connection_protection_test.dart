import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/settings_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge, profile;

const enabled = ConnectionProtection(
  supported: true,
  enabled: true,
  active: false,
  systemManaged: false,
);
const unknownAndroid = ConnectionProtection(
  supported: true,
  enabled: null,
  active: false,
  systemManaged: true,
);

class ProtectionBridge extends FakeBridge
    implements ConnectionProtectionBridge {
  ConnectionProtection protection = enabled;
  Future<ConnectionProtection>? read;
  Completer<void>? writing;
  Object? failure;
  int sets = 0;
  bool? requested;
  @override
  Future<ConnectionProtection> getConnectionProtection() async =>
      read == null ? protection : await read!;
  @override
  Future<ConnectionProtection> setConnectionProtection(bool value) async {
    sets++;
    requested = value;
    await writing?.future;
    if (failure != null) throw failure!;
    if (!protection.systemManaged) {
      protection = ConnectionProtection(
        supported: true,
        enabled: value,
        active: false,
        systemManaged: false,
      );
    }
    return protection;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'platform payload requires exact typed and consistent protection state',
    () {
      final valid = <String, Object?>{
        'supported': true,
        'enabled': true,
        'active': false,
        'systemManaged': false,
      };
      expect(NativeVpnBridge.decodeConnectionProtection(valid).enabled, true);
      final recovered = NativeVpnBridge.decodeConnectionProtection({
        ...valid,
        'enabled': false,
        'active': true,
      });
      expect(recovered.enabled, false);
      expect(recovered.active, true);
      expect(
        NativeVpnBridge.decodeConnectionProtection({
          ...valid,
          'enabled': null,
          'systemManaged': true,
        }).enabled,
        isNull,
      );
      for (final invalid in [
        {...valid, 'enabled': 'true'},
        {...valid, 'active': 1},
        {...valid, 'enabled': null},
        {...valid, 'supported': false, 'active': true},
        {...valid, 'secret': 'private'},
        {'supported': true},
      ]) {
        expect(
          () => NativeVpnBridge.decodeConnectionProtection(invalid),
          throwsA(isA<VpnFailure>()),
        );
      }
    },
  );

  test('methods use typed existing native channel, including false', () async {
    const channel = MethodChannel('test/protection');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'supported': true,
        'enabled': false,
        'active': false,
        'systemManaged': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final bridge = NativeVpnBridge(methods: channel);
    await bridge.getConnectionProtection();
    await bridge.setConnectionProtection(false);
    expect(calls.map((c) => c.method), [
      'getConnectionProtection',
      'setConnectionProtection',
    ]);
    expect(calls.first.arguments, isNull);
    expect(calls.last.arguments, {'enabled': false});
  });

  test(
    'confirmed state only, single writer and connection serialization',
    () async {
      final bridge = ProtectionBridge();
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await vpn.initialize();
      expect(vpn.connectionProtection.enabled, true);
      bridge.writing = Completer<void>();
      final setting = vpn.setConnectionProtection(false);
      await Future<void>.delayed(Duration.zero);
      expect(vpn.protectionBusy, true);
      expect(vpn.connectionProtection.enabled, true);
      expect(await vpn.setConnectionProtection(true), false);
      expect(await vpn.requestConnection(profile), false);
      expect(bridge.connects, 0);
      bridge.writing!.complete();
      expect(await setting, true);
      expect(vpn.connectionProtection.enabled, false);
      expect(bridge.sets, 1);
    },
  );

  test(
    'failed native write keeps confirmed choice and VPN status intact',
    () async {
      final bridge = ProtectionBridge();
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await vpn.initialize();
      bridge.failure = const VpnFailure(
        'connection_protection_requires_disconnected',
      );
      expect(await vpn.setConnectionProtection(false), false);
      expect(vpn.connectionProtection.enabled, true);
      expect(
        vpn.protectionError,
        'connection_protection_requires_disconnected',
      );
      expect(vpn.lastErrorCode, isNull);
      expect(vpn.status.phase, VpnPhase.disconnected);
      expect(vpn.commandPending, false);
    },
  );

  test(
    'late read cannot undo setter, status loss removes active assurance',
    () async {
      final bridge = ProtectionBridge();
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await vpn.initialize();
      final old = Completer<ConnectionProtection>();
      bridge.read = old.future;
      final reading = vpn.refreshConnectionProtection();
      await Future<void>.delayed(Duration.zero);
      expect(await vpn.setConnectionProtection(false), true);
      bridge.read = null;
      old.complete(enabled);
      await reading;
      await Future<void>.delayed(Duration.zero);
      expect(vpn.connectionProtection.enabled, false);
      bridge.states.addError(const VpnFailure('ipc_disconnected'));
      await Future<void>.delayed(Duration.zero);
      expect(vpn.connectionProtection.active, false);
      expect(vpn.connectionProtection.enabled, isNull);
    },
  );

  test(
    'Android handoff never claims desired flag until OS confirms it',
    () async {
      final bridge = ProtectionBridge()..protection = unknownAndroid;
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await vpn.initialize();
      expect(await vpn.setConnectionProtection(true), true);
      expect(bridge.requested, true);
      expect(vpn.connectionProtection.enabled, isNull);
      bridge.protection = const ConnectionProtection(
        supported: true,
        enabled: true,
        active: true,
        systemManaged: true,
      );
      await vpn.refreshConnectionProtection();
      expect(vpn.connectionProtection.active, true);
      expect(vpn.connectionProtection.enabled, true);
    },
  );

  testWidgets(
    'settings row and switch toggle directly without protection dialog',
    (tester) async {
      final bridge = ProtectionBridge();
      final vpn = VpnController(bridge);
      final app = AppController.demo();
      await vpn.initialize();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: SettingsSheet(
              controller: app,
              vpn: vpn,
              themeMode: ThemeMode.dark,
              onThemeChanged: (_) {},
              onAdd: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('settings-protection'));
      await tester.ensureVisible(row);
      await tester.tap(find.text('Защита соединения'));
      await tester.pumpAndSettle();
      expect(bridge.sets, 1);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const Key('connection-protection-switch')),
            )
            .value,
        false,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('connection-protection-switch')));
      await tester.pumpAndSettle();
      expect(bridge.sets, 2);
      expect(vpn.connectionProtection.enabled, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      vpn.dispose();
      app.dispose();
      await bridge.close();
    },
  );
}
