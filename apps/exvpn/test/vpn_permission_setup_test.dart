import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/services/vpn_permission_setup.dart';
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/vpn_permission_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

class PermissionBridge extends FakeBridge implements VpnPermissionSetupBridge {
  String? failure = 'permission_denied';
  Completer<void>? connectWait;
  int reads = 0;
  int vpnSettings = 0;
  int appSettings = 0;
  VpnPermissionSetup setup = const VpnPermissionSetup(
    vpn: VpnPermissionState.required,
    notifications: NotificationPermissionState.required,
    vendor: AndroidVendor.android,
  );

  @override
  Future<void> connect(ConnectionProfile profile) async {
    connects++;
    await connectWait?.future;
    if (failure case final code?) throw VpnFailure(code);
  }

  @override
  Future<VpnPermissionSetup> getVpnPermissionSetup() async {
    reads++;
    return setup;
  }

  @override
  Future<void> openSystemProtectionSettings() async {
    vpnSettings++;
  }

  @override
  Future<void> openAppPermissionSettings() async {
    appSettings++;
  }
}

Future<({AppController app, VpnController vpn})> mountHome(
  WidgetTester tester,
  PermissionBridge bridge,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = const Size(426, 922);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = AppController();
  app.addSubscription(
    raw:
        'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample\n'
        'vless://00000000-0000-4000-8000-000000000002@other.invalid:443?security=tls#Other',
  );
  final vpn = VpnController(bridge);
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
        latencyProbe: (_) async => const ProbeResult(reachable: false),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    vpn.dispose();
    await bridge.close();
  });
  return (app: app, vpn: vpn);
}

void androidTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('permission DTO rejects unknown fields, versions and types', () {
    final valid = <String, Object?>{
      'schema': 1,
      'vpn': 'required',
      'notifications': 'required',
      'vendor': 'xiaomi',
    };
    final setup = VpnPermissionSetup.decode(valid);
    expect(setup.vpn, VpnPermissionState.required);
    expect(setup.vendor, AndroidVendor.xiaomi);
    for (final invalid in <Object?>[
      null,
      [],
      {...valid, 'schema': 2},
      {...valid, 'schema': 1.0},
      {...valid, 'vpn': true},
      {...valid, 'vpn': 'unknown'},
      {...valid, 'notifications': null},
      {...valid, 'vendor': 'private-provider'},
      {...valid, 'otherVpnPackage': 'private-value'},
      {...valid}..remove('notifications'),
    ]) {
      expect(() => VpnPermissionSetup.decode(invalid), throwsFormatException);
    }
  });

  test(
    'permission methods use fixed null-argument native operations',
    () async {
      const channel = MethodChannel('test/permission-setup');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'getVpnPermissionSetup') {
          return {
            'schema': 1,
            'vpn': 'restricted',
            'notifications': 'granted',
            'vendor': 'android',
          };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final bridge = NativeVpnBridge(methods: channel);
      expect(
        (await bridge.getVpnPermissionSetup()).vpn,
        VpnPermissionState.restricted,
      );
      await bridge.openAppPermissionSettings();
      expect(calls.map((call) => call.method), [
        'getVpnPermissionSetup',
        'openAppPermissionSettings',
      ]);
      expect(calls.every((call) => call.arguments == null), isTrue);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'schema': 1, 'vpn': 'unknown'},
      );
      await expectLater(
        bridge.getVpnPermissionSetup(),
        throwsA(
          isA<VpnFailure>().having(
            (e) => e.code,
            'safe code',
            'invalid_native_response',
          ),
        ),
      );
    },
  );

  androidTestWidgets(
    'permission failure while paused presents once on resume without retry',
    (tester) async {
      final bridge = PermissionBridge()..connectWait = Completer<void>();
      await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pump();
      expect(bridge.connects, 1);
      expect(
        bridge.reads,
        0,
        reason: 'first connect must open the ordinary OS prompt directly',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.connectWait!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-permission-setup')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-permission-setup')), findsOneWidget);
      expect(bridge.connects, 1);
      expect(bridge.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.reads, 1);
      await tester.tap(find.byKey(const Key('vpn-permission-close')));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-permission-setup')), findsNothing);
      expect(bridge.connects, 1);
      expect(bridge.reads, 1);
    },
  );

  androidTestWidgets(
    'only a second explicit allow action retries; notification denial does not block it',
    (tester) async {
      final bridge = PermissionBridge();
      await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(bridge.connects, 1);
      expect(find.byKey(const Key('vpn-permission-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vpn-permission-settings')));
      await tester.pumpAndSettle();
      expect(bridge.vpnSettings, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        bridge.connects,
        1,
        reason: 'settings return must not reconnect automatically',
      );
      await tester.tap(find.byKey(const Key('vpn-permission-retry')));
      await tester.pumpAndSettle();
      expect(bridge.connects, 2);
      expect(find.byKey(const Key('vpn-permission-setup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vpn-permission-close')));
      await tester.pumpAndSettle();
      expect(bridge.connects, 2);
    },
  );

  androidTestWidgets(
    'changing selected profile cancels deferred permission presentation',
    (tester) async {
      final bridge = PermissionBridge()..connectWait = Completer<void>();
      final state = await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.connectWait!.complete();
      await tester.pumpAndSettle();
      final group = state.app.groups.single;
      state.app.selectServer(
        groupId: group.id,
        serverId: group.servers.last.id,
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-permission-setup')), findsNothing);
      expect(bridge.connects, 1);
      expect(bridge.reads, 0);
    },
  );

  for (final failure in ['transport_unreachable', 'permission_cancelled']) {
    androidTestWidgets('$failure never opens permission recovery', (
      tester,
    ) async {
      final bridge = PermissionBridge()..failure = failure;
      await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-permission-setup')), findsNothing);
      expect(bridge.reads, 0);
    });
  }

  androidTestWidgets(
    'restricted device offers settings and no futile permission retry',
    (tester) async {
      final bridge = PermissionBridge()
        ..failure = 'vpn_permission_restricted'
        ..setup = const VpnPermissionSetup(
          vpn: VpnPermissionState.restricted,
          notifications: NotificationPermissionState.required,
          vendor: AndroidVendor.xiaomi,
        );
      await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.text('VPN ограничен системой'), findsOneWidget);
      expect(find.byKey(const Key('vpn-permission-retry')), findsNothing);
      expect(find.byKey(const Key('vpn-permission-settings')), findsOneWidget);
      expect(
        find.byKey(const Key('vpn-permission-app-settings')),
        findsNothing,
      );
      expect(bridge.connects, 1);
    },
  );

  androidTestWidgets(
    'Xiaomi app-settings failure stays local and reveals no platform payload',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('ru')],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => VpnPermissionSheet(
                  setup: const VpnPermissionSetup(
                    vpn: VpnPermissionState.unavailable,
                    notifications: NotificationPermissionState.required,
                    vendor: AndroidVendor.xiaomi,
                  ),
                  onVpnSettings: () async => true,
                  onAppSettings: () async =>
                      throw StateError('private diagnostic'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vpn-permission-app-settings')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Не удалось открыть настройки. Откройте раздел VPN в настройках телефона.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private diagnostic'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
