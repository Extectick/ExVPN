import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/exvpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
}
