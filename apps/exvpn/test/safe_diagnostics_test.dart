import 'dart:convert';

import 'package:exvpn/services/safe_diagnostics.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostics never copies native payload or active profile identity',
    () {
      const secret = 'private-endpoint-and-credentials';
      final report = safeDiagnostics(
        status: const VpnStatus(
          phase: VpnPhase.error,
          processCrashProtection: false,
          activeProfileId: secret,
          errorCode: secret,
        ),
        platform: secret,
        coreVersion: secret,
        errorCode: secret,
        secureStorageAvailable: false,
      );
      expect(report, isNot(contains(secret)));
      final fields = jsonDecode(report) as Map<String, dynamic>;
      expect(fields['errorCode'], 'native_failure');
      expect(fields['coreVersion'], isNull);
      expect(fields['platform'], 'unknown');
      expect(fields.keys, isNot(contains('activeProfileId')));
    },
  );

  test('diagnostics retains only useful confirmed status and stable codes', () {
    final fields = jsonDecode(
      safeDiagnostics(
        status: const VpnStatus(
          phase: VpnPhase.blocked,
          processCrashProtection: true,
        ),
        platform: 'android',
        coreVersion: '26.10.10',
        errorCode: 'tunnel_https_failed',
        secureStorageAvailable: true,
      ),
    ) as Map<String, dynamic>;
    expect(fields['vpnPhase'], 'blocked');
    expect(fields['processCrashProtection'], true);
    expect(fields['coreVersion'], '26.10.10');
    expect(fields['errorCode'], 'tunnel_https_failed');
  });
}
