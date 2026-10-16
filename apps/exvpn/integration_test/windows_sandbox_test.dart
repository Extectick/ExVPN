// SPDX-License-Identifier: Apache-2.0
// Standalone guest-only test entry point. Never used by production builds.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:exvpn/build_identity.dart';
import 'package:exvpn/main.dart';
import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _input = r'C:\ExVPN-App-QA';
const _output = r'C:\ExVPN-App-QA-Results';
const _private = r'C:\ExVPN-App-QA-Private';
const _installed = r'C:\Program Files\ExVPN UI QA';
const _fixtureNames = [
  'VLESS TCP',
  'VLESS REALITY',
  'VLESS Vision',
  'VLESS XHTTP',
  'XHTTP REALITY',
  'VLESS gRPC',
  'VMess',
  'Shadowsocks',
];

Future<void> main() async {
  // Refuse to initialize any VPN code outside the explicitly staged guest.
  late Map<String, dynamic> marker;
  var names = _fixtureNames;
  var importedNames = _fixtureNames;
  var transportCycles = 0;
  try {
    marker = jsonDecode(
      await File('$_input\\sandbox-bundle.json').readAsString(),
    ) as Map<String, dynamic>;
    if (!Platform.isWindows ||
        Platform.resolvedExecutable.toLowerCase() !=
            '$_installed\\exvpn.exe'.toLowerCase() ||
        marker['forbiddenHost'] == null ||
        Platform.environment['COMPUTERNAME']?.toLowerCase() ==
            (marker['forbiddenHost'] as String).toLowerCase() ||
        !await Directory(_output).exists() ||
        !await File(
          '$_private\\${marker['providerMatrix'] == true ? 'provider-subscription.txt' : 'subscription.txt'}',
        ).exists()) {
      exit(78);
    }
    if (marker['providerMatrix'] == true) {
      if (marker['faults'] == true) exit(78);
      final cases = jsonDecode(
        await File('$_private\\provider-cases.json').readAsString(),
      ) as Map;
      names = (cases['selected'] as List).cast<String>();
      importedNames = (cases['imported'] as List).cast<String>();
      if (names.isEmpty ||
          names.length > 100 ||
          importedNames.length > 5000 ||
          names.toSet().length != names.length ||
          importedNames.any(
            (name) =>
                !RegExp(r'^Provider node [1-9][0-9]{0,3}$').hasMatch(name),
          ) ||
          names.any((name) => !importedNames.contains(name))) {
        exit(78);
      }
      if (marker['networkRecovery'] == true && names.length != 1) exit(78);
    }
    if (marker['networkRecovery'] == true &&
        (marker['providerMatrix'] != true || marker['unelevated'] != true)) {
      exit(78);
    }
    final requestedCycles = marker['transportCycles'] ?? 0;
    if (requestedCycles is! int ||
        (requestedCycles != 0 &&
            (requestedCycles < 3 || requestedCycles > 20))) {
      exit(78);
    }
    transportCycles = requestedCycles;
    if (transportCycles > 0) {
      if (marker['unelevated'] != true ||
          marker['providerMatrix'] == true ||
          marker['faults'] == true ||
          marker['networkRecovery'] == true) {
        exit(78);
      }
      names = const ['VLESS gRPC', 'VLESS XHTTP', 'XHTTP REALITY'];
      importedNames = _fixtureNames;
    }
  } catch (_) {
    exit(78);
  }

  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'format': 1,
    'version': appVersionLabel,
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
    'nativeVpnMocked': false,
    'nativeImeTested': false,
    'persistentStorageTested': false,
    'ordinaryUserTokenTested': false,
    'distinctEgressTested': false,
    'allProtocolsPassed': false,
    'faultsRequested': marker['faults'] == true,
    'faultsPassed': false,
    'runId': marker['runId'],
    'providerMatrix': marker['providerMatrix'] == true,
    'networkRecoveryRequested': marker['networkRecovery'] == true,
    'networkRecoveryPassed': false,
    if (transportCycles > 0) 'transportCycles': transportCycles,
    'profiles': <Object?>[],
  };
  Future<void> save() => File('$_output\\flutter-report.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  // integration_test can also run as a bundled executable; no driver/VM port
  // is opened. Its authoritative completion signal determines the exit code.
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      report['frameworkPassed'] = passed;
      report['finishedUtc'] = DateTime.now().toUtc().toIso8601String();
      await save();
      exit(passed ? 0 : 1);
    }),
  );

  testWidgets('real Windows service and TUN through Flutter controls', (
    tester,
  ) async {
    if (marker['unelevated'] == true) {
      final launch = jsonDecode(
        await File('$_output\\launch-report.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(launch['runId'], marker['runId']);
      expect(launch['administratorToken'], isFalse);
      expect(launch['elevated'], isFalse);
      expect(launch['mediumIntegrity'], isTrue);
      expect(launch['adminPrivilegesAbsent'], isTrue);
      expect(launch['sameInstallerOwner'], isTrue);
      expect(launch['processTokenVerified'], isTrue);
      expect(launch['privilegedAccessDenied'], isTrue);
      report['ordinaryUserTokenTested'] = true;
      report['tokenMethod'] = launch['tokenMethod'];
    }
    final controller = AppController();
    final vpn = VpnController(NativeVpnBridge());
    final boundary = GlobalKey();
    var ownedAttempt = false;
    final results = report['profiles']! as List<Object?>;
    Future<void> progress(String value) async {
      report['stage'] = value;
      await save();
    }

    Future<void> snapshot(String name) async {
      await tester.pump(const Duration(milliseconds: 120));
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$_output\\$name.png')
            .writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    }

    // Only text entry uses Flutter's documented synthetic IME. Method/event
    // channels for VPN, native storage and networking remain unmodified.
    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    try {
      await progress('initializing');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ExVpnApp(controller: controller, vpn: vpn),
        ),
      );
      await _until(tester, () => vpn.initialized && !vpn.commandPending, 20);
      report['initialState'] = vpn.status.phase.name;
      report['initialErrorCode'] = vpn.lastErrorCode;
      report['initialCanDisconnect'] = vpn.canDisconnect;
      await save();
      if (vpn.status.phase != VpnPhase.disconnected ||
          vpn.lastErrorCode != null) {
        await snapshot('initialization-failed');
      }
      expect(
        vpn.status.phase,
        VpnPhase.disconnected,
        reason: 'Guest must start disconnected',
      );
      expect(vpn.lastErrorCode, isNull, reason: 'Native IPC must initialize');
      expect(
        vpn.exclusions,
        isEmpty,
        reason: 'Guest must start without exclusions',
      );
      report['nativeInitialized'] = true;
      report['baseline'] = await _probe('numeric');
      expect(
        (report['baseline'] as Map)['success'],
        isTrue,
        reason: 'Baseline HTTPS unavailable',
      );
      await _tap(tester, find.byKey(const Key('add-button')));
      await _tap(tester, find.text('Текст'));
      await tester.enterText(
        find.byKey(const Key('subscription-name')),
        'Лабораторная подписка',
      );
      await tester.enterText(
        find.byKey(const Key('subscription-input')),
        await File(
          '$_private\\${marker['providerMatrix'] == true ? 'provider-subscription.txt' : 'subscription.txt'}',
        ).readAsString(),
      );
      // No image is captured while the private input is displayed.
      await _tap(tester, find.byKey(const Key('import-submit')));
      await _until(tester, () => controller.groups.length == 1, 10);
      expect(
        controller.groups.single.servers.map((e) => e.name).toSet(),
        importedNames.toSet(),
      );
      report['importedCount'] = controller.groups.single.servers.length;
      await snapshot('imported');
      final attempts = [
        for (
          var cycle = 1;
          cycle <= (transportCycles > 0 ? transportCycles : 1);
          cycle++
        )
          for (final name in names) (cycle: cycle, name: name),
      ];
      for (final attempt in attempts) {
        final name = attempt.name;
        final result = <String, Object?>{
          'name': name,
          if (transportCycles > 0) 'cycle': attempt.cycle,
          'passed': false,
        };
        results.add(result);
        await progress('connecting $name');
        try {
          final group = controller.groups.single;
          final server = group.servers.singleWhere((s) => s.name == name);
          await _tap(
            tester,
            find.byKey(ValueKey('server-${group.id}-${server.id}')),
          );
          expect(controller.selectedServer?.id, server.id);
          ownedAttempt = true;
          await _tap(tester, find.byKey(const Key('connect-button')));
          await _until(
            tester,
            () =>
                !vpn.commandPending &&
                (vpn.status.phase == VpnPhase.connected ||
                    vpn.status.phase == VpnPhase.error ||
                    vpn.status.phase == VpnPhase.blocked),
            70,
          );
          result['state'] = vpn.status.phase.name;
          result['errorCode'] = vpn.lastErrorCode;
          if (vpn.status.phase != VpnPhase.connected) {
            throw StateError('native_connection_failed');
          }
          expect(vpn.status.activeProfileId, server.profile.id);
          expect(vpn.status.connectedAt, isNotNull);
          // This is a release-acceptance claim, not the raw WFP latch. The
          // development bridge deliberately keeps it false until E1 is closed.
          result['releaseProtectionClaimed'] =
              vpn.status.processCrashProtection;
          expect(vpn.status.processCrashProtection, isFalse);
          await progress('probing $name');
          final numeric = await _probe('numeric');
          final dns = await _probe('dns-tun');
          final health = await _probe('health');
          result.addAll({
            'numericHttps': numeric,
            'tunDns': dns,
            'hostnameHttps': health,
          });
          expect(
            numeric['success'],
            isTrue,
            reason: 'Independent numeric HTTPS failed',
          );
          expect(dns['success'], isTrue, reason: 'Independent TUN DNS failed');
          expect(
            health['httpStatus'],
            204,
            reason: 'Independent hostname HTTPS failed',
          );
          if (marker['providerMatrix'] == true) {
            final baselineHash = (report['baseline'] as Map)['egressIpSha256'];
            expect(baselineHash, isA<String>());
            expect(numeric['egressIpSha256'], isA<String>());
            expect(
              numeric['egressIpSha256'],
              isNot(baselineHash),
              reason: 'Provider egress must differ from the direct baseline',
            );
            result['distinctEgress'] = true;
          }
          await _until(
            tester,
            () =>
                vpn.statisticsAvailable &&
                vpn.stats.uploadBytes > 0 &&
                vpn.stats.downloadBytes > 0,
            10,
          );
          result['trafficCountersIncreased'] = true;
          if (transportCycles == 0) {
            await snapshot('connected-${names.indexOf(name)}');
          } else if (attempt.cycle == 1 || attempt.cycle == transportCycles) {
            await snapshot('connected-${attempt.cycle}-${names.indexOf(name)}');
          }
          if (marker['networkRecovery'] == true) {
            final recovery = <String, Object?>{};
            result['networkRecovery'] = recovery;
            final initialConnectedAt = vpn.status.connectedAt;
            await progress('disabling guest adapter');
            await _coordinate(tester, marker, 1, 'network-down');
            final down = jsonDecode(
              await File('$_output\\network-Down.json').readAsString(),
            ) as Map;
            expect(down['runId'], marker['runId']);
            expect(down['adapterDisabled'], isTrue);
            expect(down['guardArmed'], isTrue);
            recovery['adapterDisabled'] = true;
            recovery['guardRetainedWhileOffline'] = true;
            final offline = await _probe('numeric');
            recovery['offlineHttps'] = offline;
            expect(offline['success'], isFalse);
            expect(offline['error'], 'network');
            await _until(
              tester,
              () => vpn.status.phase == VpnPhase.reconnecting,
              40,
            );
            expect(vpn.lastErrorCode, 'transport_unreachable');
            recovery['offlineDetectedByUi'] = true;
            await snapshot('network-offline');
            await progress('enabling guest adapter');
            await _coordinate(tester, marker, 2, 'network-up');
            final up = jsonDecode(
              await File('$_output\\network-Up.json').readAsString(),
            ) as Map;
            expect(up['runId'], marker['runId']);
            expect(up['adapterUp'], isTrue);
            expect(up['guardArmed'], isTrue);
            recovery['guardRetainedAfterAdapterReturn'] = true;
            await _until(
              tester,
              () => vpn.status.phase == VpnPhase.connected,
              75,
            );
            expect(vpn.status.activeProfileId, server.profile.id);
            expect(vpn.status.connectedAt, isNotNull);
            expect(
              vpn.status.connectedAt!.isAfter(initialConnectedAt!),
              isTrue,
            );
            final recoveredNumeric = await _probe('numeric');
            final recoveredDns = await _probe('dns-tun');
            final recoveredHealth = await _probe('health');
            recovery.addAll({
              'restoredNumericHttps': recoveredNumeric,
              'restoredTunDns': recoveredDns,
              'restoredHostnameHttps': recoveredHealth,
            });
            expect(recoveredNumeric['success'], isTrue);
            expect(recoveredNumeric['egressIpSha256'], isA<String>());
            expect(recoveredDns['success'], isTrue);
            expect(recoveredHealth['httpStatus'], 204);
            expect(
              recoveredNumeric['egressIpSha256'],
              isNot((report['baseline'] as Map)['egressIpSha256']),
            );
            recovery['sameProfileReconnectedWithoutUserAction'] = true;
            recovery['distinctEgressAfterRecovery'] = true;
            report['networkRecoveryPassed'] = true;
            await snapshot('network-recovered');
          }
          await _tap(tester, find.byKey(const Key('connect-button')));
          await _until(
            tester,
            () =>
                !vpn.commandPending &&
                vpn.status.phase == VpnPhase.disconnected,
            30,
          );
          result['explicitDisconnect'] = true;
          ownedAttempt = false;
          result['passed'] = true;
        } catch (_) {
          // Raw framework/native exceptions may include the profile. Report
          // only the phase and stable allowlisted native diagnostic code.
          result['state'] = vpn.status.phase.name;
          result['errorCode'] = vpn.lastErrorCode;
          result['failedAt'] = report['stage'];
        } finally {
          if (ownedAttempt) {
            await vpn.disconnect();
            await _until(
              tester,
              () =>
                  !vpn.commandPending &&
                  vpn.status.phase == VpnPhase.disconnected,
              30,
            );
            ownedAttempt = false;
          }
          if (transportCycles > 0) {
            await progress('observing disconnect');
            await _coordinate(
              tester,
              marker,
              results.length,
              'observe-disconnect',
              channel: 'transport',
            );
            result['disconnectObserved'] = true;
          }
          await save();
        }
      }
      report['allProtocolsPassed'] = results.every(
        (r) => (r as Map)['passed'] == true,
      );
      report['distinctEgressTested'] =
          marker['providerMatrix'] == true &&
          results.every((r) => (r as Map)['distinctEgress'] == true);
      if (marker['faults'] == true && report['allProtocolsPassed'] == true) {
        final faults = <String, Object?>{};
        report['faults'] = faults;
        await progress('selecting exclusion');
        final holder = await Process.start('$_installed\\excluded-probe.exe', [
          '-mode',
          'hold',
        ]);
        unawaited(holder.stdout.drain<void>());
        unawaited(holder.stderr.drain<void>());
        try {
          await _tap(tester, find.byKey(const Key('settings-button')));
          await _tap(tester, find.text('Исключения приложений'));
          await progress('loading applications');
          await _until(
            tester,
            () => find.byType(CheckboxListTile).evaluate().isNotEmpty,
            20,
          );
          final excluded = find.byWidgetPredicate(
            (widget) =>
                widget is CheckboxListTile &&
                widget.subtitle is Text &&
                _pathKey((widget.subtitle as Text).data ?? '') ==
                    _pathKey('$_installed\\excluded-probe.exe'),
          );
          await progress('finding excluded application');
          await tester.scrollUntilVisible(
            excluded,
            250,
            scrollable: find.byType(Scrollable).last,
            maxScrolls: 40,
          );
          await _tap(tester, excluded);
          await progress('saving exclusion');
          await _tap(tester, find.text('Сохранить'));
          await _until(
            tester,
            () => find.byType(CheckboxListTile).evaluate().isEmpty,
            15,
          );
          // Outside the 600px settings sheet in the real desktop viewport.
          await tester.tapAt(const Offset(4, 4));
          await tester.pump(const Duration(milliseconds: 400));
          expect(vpn.exclusions.map(_pathKey).toSet(), {
            _pathKey('$_installed\\excluded-probe.exe'),
          });
          faults['exclusionSelectedThroughUi'] = true;
        } finally {
          holder.kill();
          await holder.exitCode.timeout(const Duration(seconds: 10));
        }
        final group = controller.groups.single;
        final server = group.servers.singleWhere((s) => s.name == 'VLESS TCP');
        await _tap(
          tester,
          find.byKey(ValueKey('server-${group.id}-${server.id}')),
        );
        ownedAttempt = true;
        await progress('connecting with exclusion');
        await _tap(tester, find.byKey(const Key('connect-button')));
        await _until(
          tester,
          () => !vpn.commandPending && vpn.status.phase == VpnPhase.connected,
          70,
        );
        final connected = await _probePair();
        faults['connected'] = connected;
        expect((connected['protected'] as Map)['success'], isTrue);
        expect((connected['excluded'] as Map)['success'], isTrue);
        await snapshot('exclusion-connected');
        await progress('stopping fixture');
        await _coordinate(tester, marker, 1, 'stop-fixture');
        final outage = await _probePair();
        faults['serverOutage'] = outage;
        expect((outage['protected'] as Map)['error'], 'network');
        expect((outage['protected'] as Map)['success'], isFalse);
        expect((outage['excluded'] as Map)['success'], isTrue);
        await _until(
          tester,
          () => vpn.status.phase == VpnPhase.reconnecting,
          40,
        );
        expect(vpn.lastErrorCode, 'transport_unreachable');
        expect(
          find.textContaining('Связь с VPN-сервером потеряна.'),
          findsOneWidget,
        );
        faults['outageDetectedByUi'] = true;
        faults['outageCode'] = vpn.lastErrorCode;
        await snapshot('server-outage');
        await progress('crashing SCM service');
        await _coordinate(tester, marker, 2, 'crash-service');
        final crashed = await _probePair();
        faults['serviceCrash'] = crashed;
        for (final value in crashed.values.cast<Map>()) {
          expect(value['success'], isFalse);
          expect(
            value['error'],
            'network',
            reason: 'Process/JSON failure must not count as network blocking',
          );
        }
        await _until(tester, () => vpn.status.phase == VpnPhase.error, 15);
        faults['serviceLossDetectedByUi'] = true;
        await snapshot('service-crashed');
        await progress('restarting SCM service');
        await _coordinate(tester, marker, 3, 'restart-service');
        await _until(tester, () => vpn.status.phase == VpnPhase.blocked, 20);
        expect(vpn.lastErrorCode, 'guard_recovered');
        expect(find.textContaining('Служба VPN перезапущена.'), findsOneWidget);
        expect(find.text('Отключить'), findsOneWidget);
        await vpn.loadExclusions();
        expect(vpn.exclusions.map(_pathKey).toSet(), {
          _pathKey('$_installed\\excluded-probe.exe'),
        });
        faults['exclusionsRestoredAfterServiceCrash'] = true;
        final recovered = await _probePair();
        faults['serviceRestart'] = recovered;
        for (final value in recovered.values.cast<Map>()) {
          expect(value['success'], isFalse);
          expect(value['error'], 'network');
        }
        faults['restartRemainedBlocked'] = true;
        faults['restartCode'] = vpn.lastErrorCode;
        await snapshot('service-restarted-blocked');
        await progress('explicit recovery disconnect');
        await _tap(tester, find.byKey(const Key('connect-button')));
        await _until(
          tester,
          () =>
              !vpn.commandPending && vpn.status.phase == VpnPhase.disconnected,
          30,
        );
        ownedAttempt = false;
        await vpn.loadExclusions();
        expect(vpn.exclusions.map(_pathKey).toSet(), {
          _pathKey('$_installed\\excluded-probe.exe'),
        });
        faults['exclusionsRetainedAfterDisconnect'] = true;
        await vpn.setExclusions({});
        expect(vpn.exclusions, isEmpty);
        final restored = await _probePair();
        faults['explicitRecovery'] = restored;
        expect((restored['protected'] as Map)['success'], isTrue);
        expect((restored['excluded'] as Map)['success'], isTrue);
        report['faultsPassed'] = true;
      }
      report['afterDisconnect'] = await _probe('numeric');
      report['cleanupDisconnected'] = vpn.status.phase == VpnPhase.disconnected;
      await progress('completed');
      expect(
        report['allProtocolsPassed'],
        isTrue,
        reason: 'See sanitized per-protocol report',
      );
      expect((report['afterDisconnect'] as Map)['success'], isTrue);
      if (marker['faults'] == true) expect(report['faultsPassed'], isTrue);
      if (marker['networkRecovery'] == true) {
        expect(report['networkRecoveryPassed'], isTrue);
      }
      expect(tester.takeException(), isNull);
    } finally {
      if (ownedAttempt) {
        await vpn.disconnect();
        report['cleanupDisconnected'] =
            vpn.status.phase == VpnPhase.disconnected;
      }
      await save();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, timeout: const Timeout(Duration(minutes: 18)));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  int seconds,
) async {
  final limit = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) throw StateError('bounded_wait_expired');
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
}

Future<Map<String, dynamic>> _probe(
  String mode, {
  bool excluded = false,
}) async {
  var stage = 'start';
  try {
    final name = excluded ? 'excluded-probe.exe' : 'protected-probe.exe';
    final process = await Process.start('$_installed\\$name', ['-mode', mode]);
    stage = 'wait';
    final stdout = process.stdout.transform(utf8.decoder).join();
    // The fixed probe has a 15 s network deadline; enforce a process deadline too.
    final stderr = process.stderr.drain<void>();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await stderr;
    final output = await stdout;
    if (code != 0) {
      return {
        'success': false,
        'error': 'probe_process',
        'stage': stage,
        'exitCode': code,
      };
    }
    stage = 'decode';
    final value = jsonDecode(output) as Map<String, dynamic>;
    return {
      for (final key in [
        'success',
        'mode',
        'httpStatus',
        'responseBytes',
        'egressIpSha256',
        'durationMs',
        'addressCount',
        'error',
      ])
        if (value.containsKey(key)) key: value[key],
    };
  } on ProcessException catch (error) {
    // Numeric OS code only: messages/arguments can contain private paths.
    return {
      'success': false,
      'error': 'probe_process',
      'stage': stage,
      'osErrorCode': error.errorCode,
    };
  } catch (_) {
    return {'success': false, 'error': 'probe_process', 'stage': stage};
  }
}

Future<Map<String, Object?>> _probePair() async {
  final values = await Future.wait([
    _probe('numeric'),
    _probe('numeric', excluded: true),
  ]);
  return {'protected': values[0], 'excluded': values[1]};
}

String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();

Future<void> _coordinate(
  WidgetTester tester,
  Map<String, dynamic> marker,
  int step,
  String action, {
  String channel = 'fault',
}) async {
  if (channel != 'fault' && channel != 'transport') {
    throw StateError('unknown_coordinator_channel');
  }
  final temporary = File('$_output\\$channel-request.tmp');
  await temporary.writeAsString(
    jsonEncode({'runId': marker['runId'], 'step': step, 'action': action}),
    flush: true,
  );
  await temporary.rename('$_output\\$channel-request.json');
  final deadline = DateTime.now().add(const Duration(seconds: 70));
  while (DateTime.now().isBefore(deadline)) {
    final file = File('$_output\\$channel-ack.json');
    if (await file.exists()) {
      final ack = jsonDecode(await file.readAsString()) as Map;
      if (ack['runId'] == marker['runId'] && ack['step'] == step) {
        if (ack['ok'] != true) throw StateError('fault_coordinator_rejected');
        return;
      }
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
  throw StateError('fault_coordinator_timeout');
}
