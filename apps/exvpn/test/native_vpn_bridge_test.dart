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
    'automatic group crosses only existing authenticated connect channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = NativeVpnBridge(methods: channel);
      ConnectionProfile node(String id) => ConnectionProfile(
        id: id,
        name: 'Synthetic',
        protocol: ProxyProtocol.vless,
        server: '$id.example',
        port: 443,
        uuid: '00000000-0000-4000-8000-000000000001',
        transport: const Transport(),
        tls: TlsOptions(enabled: true),
      );
      final first = node('first');
      final second = node('second');
      await bridge.connectAutomatic(
        first,
        [first, second],
        VpnMode.vpn,
        replace: true,
      );
      expect(calls.single.method, 'reconnect');
      expect((calls.single.arguments as Map)['automaticProfiles'], [
        first.toNativeJson(),
        second.toNativeJson(),
      ]);
      await bridge.clearAutomaticSelection();
      expect(calls.last.method, 'clearAutomaticSelection');
      expect(calls.any((c) => c.method == 'disconnect'), isFalse);
      for (final invalid in <List<ConnectionProfile>>[
        [],
        [first, first],
        [second],
        List.filled(33, first),
      ]) {
        await expectLater(
          bridge.connectAutomatic(first, invalid, VpnMode.vpn, replace: false),
          throwsA(isA<VpnFailure>()),
        );
      }
      expect(calls, hasLength(2));
    },
  );

  test('native automatic policy flag is typed and defaults to disabled', () {
    final status = {'phase': 'disconnected', 'processCrashProtection': false};
    expect(NativeVpnBridge.decodeStatus(status).automaticSelection, isFalse);
    expect(
      NativeVpnBridge.decodeStatus({...status, 'automaticSelection': true})
          .automaticSelection,
      isTrue,
    );
    expect(
      () => NativeVpnBridge.decodeStatus({
        ...status,
        'automaticSelection': 'true',
      }),
      throwsA(isA<VpnFailure>()),
    );
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

  group('application routing and icons', () {
    test(
      'typed policy retains disabled selection and sorts only outgoing IDs',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getApplicationRouting') {
            return {
              'mode': 'disabled',
              'applications': ['app.saved'],
            };
          }
          return null;
        });
        final bridge = NativeVpnBridge(methods: channel);
        final current = await bridge.getApplicationRouting();
        expect(current.mode, ApplicationRoutingMode.disabled);
        expect(current.applicationIds, {'app.saved'});
        await bridge.setApplicationRouting(
          ApplicationRoutingPolicy(
            mode: ApplicationRoutingMode.include,
            applicationIds: {'app.z', 'app.a'},
          ),
        );
        expect(calls.last.method, 'setApplicationRouting');
        expect(calls.last.arguments, {
          'mode': 'include',
          'applications': ['app.a', 'app.z'],
        });
        expect(calls.where((c) => c.method == 'setExclusions'), isEmpty);
      },
    );

    test(
      'old native fallback rejects include without changing exclusions',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getApplicationRouting' ||
              call.method == 'setApplicationRouting') {
            throw PlatformException(
              code: 'native_method_unsupported',
              message: 'private path',
            );
          }
          return call.method == 'getExclusions' ? ['app.old'] : null;
        });
        final bridge = NativeVpnBridge(methods: channel);
        expect(
          (await bridge.getApplicationRouting()).mode,
          ApplicationRoutingMode.exclude,
        );
        await expectLater(
          bridge.setApplicationRouting(
            ApplicationRoutingPolicy(
              mode: ApplicationRoutingMode.include,
              applicationIds: {'app.new'},
            ),
          ),
          throwsA(
            isA<VpnFailure>().having(
              (e) => e.code,
              'code',
              'application_routing_unsupported',
            ),
          ),
        );
        expect(calls.where((c) => c.method == 'setExclusions'), isEmpty);
        await bridge.setApplicationRouting(
          ApplicationRoutingPolicy(
            mode: ApplicationRoutingMode.disabled,
            applicationIds: {'app.remembered'},
          ),
        );
        expect(calls.last.method, 'setExclusions');
        expect(calls.last.arguments, {'applications': <String>[]});
        await bridge.setApplicationRouting(
          ApplicationRoutingPolicy(
            mode: ApplicationRoutingMode.exclude,
            applicationIds: {'app.new'},
          ),
        );
        expect(calls.last.arguments, {
          'applications': ['app.new'],
        });
      },
    );

    test(
      'malformed modern policy never silently falls back to exclusions',
      () async {
        for (final raw in [
          null,
          {'mode': null, 'applications': <String>[]},
          {'mode': 'all', 'applications': <String>[]},
          {'mode': 'include', 'applications': null},
          {
            'mode': 'include',
            'applications': [1],
          },
          {
            'mode': 'include',
            'applications': ['app.same', 'app.same'],
          },
          {
            'mode': 'include',
            'applications': ['app\nunsafe'],
          },
          {'mode': 'include', 'applications': <String>[], 'extra': true},
        ]) {
          final calls = <String>[];
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return raw;
          });
          await expectLater(
            NativeVpnBridge(methods: channel).getApplicationRouting(),
            throwsA(
              isA<VpnFailure>().having(
                (e) => e.code,
                'code',
                'invalid_native_response',
              ),
            ),
          );
          expect(calls, ['getApplicationRouting']);
        }
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return null;
        });
        await expectLater(
          NativeVpnBridge(methods: channel).setApplicationRouting(
            ApplicationRoutingPolicy(
              mode: ApplicationRoutingMode.include,
              applicationIds: {for (var i = 0; i < 129; i++) 'app.$i'},
            ),
          ),
          throwsA(isA<VpnFailure>()),
        );
        expect(calls, 0);
      },
    );

    test('icons are optional, bounded PNG64 payloads with no caller paths in errors', () async {
      final bytes = Uint8List(33);
      bytes.setRange(0, 16, [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
      ]);
      ByteData.sublistView(bytes)
        ..setUint32(16, 64)
        ..setUint32(20, 64);
      Object? result = bytes;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return result;
      });
      final bridge = NativeVpnBridge(methods: channel);
      final icon = await bridge.getApplicationIcon('app.example');
      expect(icon, bytes);
      expect(identical(icon, bytes), isFalse);
      expect(calls.single.arguments, {'application': 'app.example'});
      for (final invalid in [
        Uint8List(64 * 1024 + 1),
        <int>[1, 2, 3],
        Uint8List.fromList(bytes)..[0] = 0,
        Uint8List.fromList(bytes)..[19] = 32,
      ]) {
        result = invalid;
        await expectLater(
          bridge.getApplicationIcon('app.example'),
          throwsA(
            isA<VpnFailure>().having(
              (e) => e.code,
              'code',
              'invalid_native_response',
            ),
          ),
        );
      }
      result = null;
      expect(await bridge.getApplicationIcon('app.example'), isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'application_icon_unavailable',
          message: 'private executable path',
        ),
      );
      expect(await bridge.getApplicationIcon('app.example'), isNull);
      expect(
        safeVpnCode('application_icon_unavailable private'),
        'native_failure',
      );
    });
  });
}
