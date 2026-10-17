import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/exvpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'native connected requires a profile, time and explicit protection flag',
    () {
      final valid = {
        'phase': 'connected',
        'processCrashProtection': false,
        'activeProfileId': 'profile-1',
        'connectedAt': 1700000000000,
      };
      expect(NativeVpnBridge.decodeStatus(valid).phase, VpnPhase.connected);
      for (final key in [
        'activeProfileId',
        'connectedAt',
        'processCrashProtection',
      ]) {
        expect(
          () => NativeVpnBridge.decodeStatus({...valid}..remove(key)),
          throwsA(isA<VpnFailure>()),
        );
      }
      expect(
        () => NativeVpnBridge.decodeStatus({...valid, 'phase': 'unknown'}),
        throwsA(isA<VpnFailure>()),
      );
    },
  );

  test(
    'native messages and unknown diagnostic payloads never reach UI',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'secret_from_native',
          message: 'private URL and credentials',
          details: {'config': 'secret'},
        ),
      );
      final bridge = NativeVpnBridge(methods: channel);
      await expectLater(
        bridge.disconnect(),
        throwsA(
          isA<VpnFailure>().having(
            (e) => e.toString(),
            'sanitized',
            'VpnFailure(native_failure)',
          ),
        ),
      );
      expect(
        NativeVpnBridge.decodeStatus({
          'phase': 'error',
          'processCrashProtection': false,
          'errorCode': 'secret_from_native',
        }).errorCode,
        'native_failure',
      );
    },
  );

  test(
    'Windows transport failure and recovered guard retain only stable codes',
    () {
      for (final entry in {
        'transport_unreachable': 'reconnecting',
        'guard_recovered': 'blocked',
        'tunnel_unreachable': 'blocked',
      }.entries) {
        final status = NativeVpnBridge.decodeStatus({
          'phase': entry.value,
          'processCrashProtection': false,
          'errorCode': entry.key,
          'message': 'private native diagnostic',
        });
        expect(status.errorCode, entry.key);
        expect(status.phase.name, entry.value);
        expect(status.processCrashProtection, isFalse);
        expect(safeVpnCode('${entry.key}: private endpoint'), 'native_failure');
      }
    },
  );

  test(
    'bridge transmits only normalized profile and reads actual exclusions',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'getExclusions' ? ['org.example.browser'] : null;
      });
      final bridge = NativeVpnBridge(methods: channel);
      final profile = const SubscriptionParser()
          .parse(
            'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
          )
          .profiles
          .single;
      await bridge.connect(profile);
      expect(calls.single.arguments, {'profile': profile.toNativeJson()});
      expect(await bridge.getExclusions(), {'org.example.browser'});
    },
  );

  test('mode status is optional for old native modules and strictly typed', () {
    final legacy = {'phase': 'disconnected', 'processCrashProtection': false};
    final old = NativeVpnBridge.decodeStatus(legacy);
    expect(old.mode, VpnMode.vpn);
    expect(old.systemProxySupported, isFalse);
    expect(old.cleanupRequired, isFalse);
    final proxy = NativeVpnBridge.decodeStatus({
      ...legacy,
      'mode': 'proxy',
      'systemProxySupported': true,
      'cleanupRequired': true,
    });
    expect(proxy.mode, VpnMode.proxy);
    expect(proxy.systemProxySupported, isTrue);
    expect(proxy.cleanupRequired, isTrue);
    for (final invalid in [
      {'mode': null},
      {'mode': 'PROXY'},
      {'mode': 1},
      {'mode': true},
      {
        'mode': ['vpn'],
      },
      {'systemProxySupported': null},
      {'systemProxySupported': 'true'},
      {'systemProxySupported': 1},
      {'cleanupRequired': null},
      {'cleanupRequired': 'true'},
      {'cleanupRequired': 1},
    ]) {
      expect(
        () => NativeVpnBridge.decodeStatus({...legacy, ...invalid}),
        throwsA(
          isA<VpnFailure>().having(
            (failure) => failure.code,
            'sanitized schema error',
            'invalid_native_response',
          ),
        ),
      );
    }
  });

  test(
    'Windows mode commands use one typed native operation per request',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final native = NativeVpnBridge(methods: channel);
      final selected = const SubscriptionParser()
          .parse(
            'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
          )
          .profiles
          .single;
      expect(native.supportsConnectionModes, isTrue);
      await native.connect(selected);
      await native.connectInMode(selected, VpnMode.proxy);
      await native.reconnect(selected, VpnMode.vpn);
      expect(calls.map((call) => call.method), [
        'connect',
        'connect',
        'reconnect',
      ]);
      expect(calls[0].arguments, {
        'profile': selected.toNativeJson(),
        'mode': 'vpn',
      });
      expect(calls[1].arguments, {
        'profile': selected.toNativeJson(),
        'mode': 'proxy',
      });
      expect(calls[2].arguments, {
        'profile': selected.toNativeJson(),
        'mode': 'vpn',
      });
    },
  );

  test('non-Windows never silently connects proxy as a VPN', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final native = NativeVpnBridge(methods: channel);
    final selected = const SubscriptionParser()
        .parse(
          'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
        )
        .profiles
        .single;
    expect(native.supportsConnectionModes, isFalse);
    for (final action in [
      () => native.connectInMode(selected, VpnMode.proxy),
      () => native.reconnect(selected, VpnMode.vpn),
    ]) {
      await expectLater(
        action(),
        throwsA(
          isA<VpnFailure>().having(
            (failure) => failure.code,
            'unsupported code',
            'mode_unsupported',
          ),
        ),
      );
    }
    expect(calls, isEmpty);
    await native.connectInMode(selected, VpnMode.vpn);
    expect(calls.single.method, 'connect');
    expect(calls.single.arguments, {'profile': selected.toNativeJson()});
  });

  test('only fixed proxy diagnostics survive native failures', () async {
    for (final code in [
      'proxy_query_failed',
      'proxy_setup_failed',
      'proxy_restore_failed',
      'proxy_settings_changed',
      'proxy_settings_conflict',
      'proxy_store_unavailable',
      'proxy_invalid_endpoint',
      'mode_unsupported',
      'mode_invalid',
      'connection_mode_rejected',
      'connection_busy',
      'proxy_unavailable',
      'proxy_exclusions_unsupported',
      'proxy_requires_guard_recovery',
      'proxy_start_failed',
      'proxy_stop_failed',
      'proxy_unreachable',
      'proxy_endpoint_unavailable',
      'proxy_bind_failed',
    ]) {
      expect(safeVpnCode(code), code);
      expect(safeVpnCode('$code private credential'), 'native_failure');
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: code,
          message: 'private system proxy configuration',
        ),
      );
      await expectLater(
        NativeVpnBridge(methods: channel).disconnect(),
        throwsA(
          isA<VpnFailure>().having((failure) => failure.code, 'code', code),
        ),
      );
    }
  });
}
