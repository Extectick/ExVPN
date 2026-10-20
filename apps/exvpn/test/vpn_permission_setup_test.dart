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

class PermissionBridge extends FakeBridge
    implements VpnPermissionSetupBridge, VpnNotificationSettingsBridge {
  String? failure = 'permission_denied';
  Completer<void>? connectWait;
  int reads = 0;
  int vpnSettings = 0;
  int appSettings = 0;
  int notificationSettings = 0;
  int notificationReads = 0;
  Completer<NotificationPermissionState>? notificationWait;
  Object? notificationError;
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

  @override
  Future<NotificationPermissionState> getNotificationPermission() async {
    notificationReads++;
    if (notificationError case final error?) throw error;
    return notificationWait == null
        ? setup.notifications
        : await notificationWait!.future;
  }

  @override
  Future<void> openNotificationSettings() async {
    notificationSettings++;
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
      await bridge.openNotificationSettings();
      expect(calls.map((call) => call.method), [
        'getVpnPermissionSetup',
        'openAppPermissionSettings',
        'openNotificationSettings',
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

  test('notification-only native read is strict and never requests VPN preparation', () async {
    const channel = MethodChannel('test/notification-only');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? reply = 'granted';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getNotificationPermission') return reply;
      if (call.method == 'openNotificationSettings') return null;
      throw StateError('VPN preparation must not be requested');
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bridge = NativeVpnBridge(methods: channel);
    final vpn = VpnController(bridge);
    try {
      expect(
        await vpn.getNotificationPermission(),
        NotificationPermissionState.granted,
      );
      reply = 'required';
      expect(
        await vpn.getNotificationPermission(),
        NotificationPermissionState.required,
      );
      for (final invalid in <Object?>[
        null,
        true,
        1,
        'GRANTED',
        'unknown',
        {'notifications': 'required'},
      ]) {
        reply = invalid;
        await expectLater(
          bridge.getNotificationPermission(),
          throwsA(
            isA<VpnFailure>().having(
              (error) => error.code,
              'safe code',
              'invalid_native_response',
            ),
          ),
        );
        expect(await vpn.getNotificationPermission(), isNull);
      }
      expect(await vpn.openNotificationSettings(), isTrue);
      expect(calls.every((call) => call.arguments == null), isTrue);
      expect(
        calls.any((call) => call.method == 'getVpnPermissionSetup'),
        isFalse,
      );
    } finally {
      vpn.dispose();
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

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
      expect(find.byKey(const Key('vpn-permission-settings')), findsNothing);
      await tester.tap(find.byKey(const Key('vpn-permission-help')));
      await tester.pumpAndSettle();
      expect(find.text('Откройте настройки VPN.'), findsOneWidget);
      expect(
        find.text('Вернитесь в ExVPN и нажмите «Повторить запрос».'),
        findsOneWidget,
      );
      expect(
        tester.widget(find.byKey(const Key('vpn-permission-settings'))),
        isA<FilledButton>(),
      );
      await tester.tap(find.byKey(const Key('vpn-permission-settings')));
      await tester.pumpAndSettle();
      expect(bridge.vpnSettings, 1);
      expect(
        tester.widget(find.byKey(const Key('vpn-permission-retry'))),
        isA<FilledButton>(),
      );
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
      expect(
        find.byKey(const Key('vpn-permission-app-settings')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('vpn-permission-more-help')));
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

  androidTestWidgets(
    'connected notification reminder waits for foreground and is shown once',
    (tester) async {
      final bridge = PermissionBridge()
        ..notificationWait = Completer<NotificationPermissionState>();
      final state = await mountHome(tester, bridge);
      final connected = VpnStatus(
        phase: VpnPhase.connected,
        processCrashProtection: false,
        activeProfileId: state.app.selectedServer!.profile.id,
        connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      bridge.emit(connected);
      await tester.pump();
      expect(bridge.notificationReads, 1);
      expect(
        bridge.reads,
        0,
        reason: 'notification UI must not call VPN prepare',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.notificationWait!.complete(bridge.setup.notifications);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-notification-hint')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-notification-hint')), findsOneWidget);
      expect(bridge.notificationSettings, 0);
      final hint = find.byKey(const Key('vpn-notification-hint'));
      await tester.tap(
        find.descendant(of: hint, matching: find.text('Включить')),
      );
      await tester.pumpAndSettle();
      expect(bridge.notificationSettings, 1);
      final reads = bridge.notificationReads;
      bridge.emit(connected);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vpn-notification-hint')), findsNothing);
      expect(bridge.notificationReads, reads);
      expect(bridge.reads, 0);
      expect(bridge.connects, 0);
      expect(bridge.disconnects, 0);
    },
  );

  androidTestWidgets(
    'notification reminder is idle-only and leaves an active VPN untouched',
    (tester) async {
      final bridge = PermissionBridge();
      final state = await mountHome(tester, bridge);
      final connected = VpnStatus(
        phase: VpnPhase.connected,
        processCrashProtection: false,
        activeProfileId: state.app.selectedServer!.profile.id,
        connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      state.vpn.protectionBusy = true;
      bridge.emit(connected);
      await tester.pump();
      expect(bridge.reads, 0);
      expect(bridge.notificationReads, 0);
      expect(find.byKey(const Key('vpn-notification-hint')), findsNothing);
      state.vpn.protectionBusy = false;
      bridge.emit(connected);
      await tester.pumpAndSettle();
      expect(bridge.notificationReads, 1);
      expect(
        bridge.reads,
        0,
        reason: 'notification UI must not call VPN prepare',
      );
      expect(find.byKey(const Key('vpn-notification-hint')), findsOneWidget);
      bridge.emit(connected);
      await tester.pumpAndSettle();
      expect(bridge.notificationReads, 1);
      expect(bridge.reads, 0);
      expect(state.vpn.status.phase, VpnPhase.connected);
      expect(bridge.disconnects, 0);
    },
  );

  for (final unavailable in [false, true]) {
    androidTestWidgets(
      'granted or unknown notification status is not presented as denied: unknown=$unavailable',
      (tester) async {
        final bridge = PermissionBridge()
          ..setup = const VpnPermissionSetup(
            vpn: VpnPermissionState.granted,
            notifications: NotificationPermissionState.granted,
            vendor: AndroidVendor.android,
          )
          ..notificationError = unavailable
              ? StateError('private native diagnostic')
              : null;
        final state = await mountHome(tester, bridge);
        bridge.emit(
          VpnStatus(
            phase: VpnPhase.connected,
            processCrashProtection: false,
            activeProfileId: state.app.selectedServer!.profile.id,
            connectedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('vpn-notification-hint')), findsNothing);
        expect(bridge.notificationSettings, 0);
        expect(bridge.reads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  androidTestWidgets(
    'Android settings retains notification action and refreshes after an explicit settings visit',
    (tester) async {
      final bridge = PermissionBridge();
      final state = await mountHome(tester, bridge);
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('settings-vpn-notification'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('Отключено в Android')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('settings-enable-vpn-notification')),
      );
      await tester.pumpAndSettle();
      expect(bridge.notificationSettings, 1);
      expect(
        bridge.reads,
        0,
        reason: 'opening settings must not call VPN prepare',
      );
      bridge.setup = const VpnPermissionSetup(
        vpn: VpnPermissionState.required,
        notifications: NotificationPermissionState.granted,
        vendor: AndroidVendor.android,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('Включено')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-enable-vpn-notification')),
        findsNothing,
      );
      expect(state.vpn.status.phase, VpnPhase.disconnected);
      expect(bridge.connects, 0);
      expect(bridge.reads, 0);
    },
  );
}
