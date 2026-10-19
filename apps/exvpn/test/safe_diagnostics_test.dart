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
    expect(fields['uiRevision'], isA<int>());
  });

  test('explicit diagnostics retains update identity without arbitrary backend strings', () {
    final fields = jsonDecode(
      safeDiagnostics(
        status: null,
        platform: 'windows',
        secureStorageAvailable: true,
        dataRevision: 42,
        dataChannel: 'beta',
        dartUpdatesAvailable: true,
        currentDartPatch: 7,
        nextDartPatch: 8,
        dartRestartRequired: true,
        dartUpdateTrack: 'stable',
      ),
    ) as Map<String, dynamic>;
    expect(fields['updates'], {
      'dataRevision': 42,
      'dataChannel': 'beta',
      'dartAvailable': true,
      'currentDartPatch': 7,
      'nextDartPatch': 8,
      'dartRestartRequired': true,
      'dartTrack': 'stable',
    });
    final rejected = safeDiagnostics(
      status: null,
      platform: 'windows',
      secureStorageAvailable: true,
      dataRevision: -1,
      dataChannel: 'private-token',
      currentDartPatch: 0,
      nextDartPatch: 0x80000000,
      dartUpdateTrack: 'https://private.invalid/token',
    );
    expect(rejected, isNot(contains('private')));
    final updateFields = (jsonDecode(rejected) as Map)['updates'] as Map;
    expect(updateFields['dataRevision'], isNull);
    expect(updateFields['currentDartPatch'], isNull);
    expect(updateFields['nextDartPatch'], isNull);
    expect(updateFields['dataChannel'], isNull);
    expect(updateFields['dartTrack'], isNull);
  });

  test(
    'diagnostics identifies the bundled patch without arbitrary suffixes',
    () {
      for (final version in [
        '26.10.10-exvpn.1',
        '26.10.10-exvpn.1-private-data',
        '26.10.10-exvpn.0',
        '26.10.10-private-data',
      ]) {
        final fields = jsonDecode(
          safeDiagnostics(
            status: null,
            platform: 'windows',
            coreVersion: version,
            secureStorageAvailable: true,
          ),
        ) as Map<String, dynamic>;
        expect(
          fields['coreVersion'],
          version == '26.10.10-exvpn.1' ? version : isNull,
        );
      }
    },
  );
}
