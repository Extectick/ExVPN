// SPDX-License-Identifier: Apache-2.0
// Guest-only entry point: real Flutter controls and installed SCM/DPAPI policy.
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

Future<void> main() async {
  late Map<String, dynamic> marker;
  try {
    marker = jsonDecode(
      await File('$_input\\sandbox-bundle.json').readAsString(),
    ) as Map<String, dynamic>;
    if (!Platform.isWindows ||
        Platform.resolvedExecutable.toLowerCase() !=
            r'C:\Program Files\ExVPN UI QA\exvpn.exe'.toLowerCase() ||
        marker['forbiddenHost'] is! String ||
        Platform.environment['COMPUTERNAME']?.toLowerCase() ==
            (marker['forbiddenHost'] as String).toLowerCase() ||
        !['reset', 'reopen'].contains(marker['policyRecovery']) ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(marker['runId'] as String) ||
        !await Directory(_output).exists()) {
      exit(78);
    }
  } catch (_) {
    exit(78);
  }
  final mode = marker['policyRecovery'] as String;
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'format': 1,
    'runId': marker['runId'],
    'version': appVersionLabel,
    'mode': mode,
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
    'nativeVpnMocked': false,
    'computerUse': false,
    'passed': false,
  };
  Future<void> save() => File('$_output\\policy-ui-$mode.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      report['frameworkPassed'] = passed;
      report['finishedUtc'] = DateTime.now().toUtc().toIso8601String();
      await save();
      exit(passed ? 0 : 1);
    }),
  );
  testWidgets('explicit policy recovery and durable reopen: $mode', (
    tester,
  ) async {
    final vpn = VpnController(NativeVpnBridge());
    final controller = AppController();
    final boundary = GlobalKey();
    Future<void> stage(String value) async {
      report['stage'] = value;
      await save();
    }

    Future<void> snapshot(String name) async {
      await tester.pump(const Duration(milliseconds: 200));
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

    try {
      await stage('initializing');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ExVpnApp(controller: controller, vpn: vpn),
        ),
      );
      await _until(tester, () => vpn.initialized && !vpn.commandPending);
      report['initialState'] = vpn.status.phase.name;
      report['initialErrorCode'] = vpn.lastErrorCode;
      report['initialCanDisconnect'] = vpn.canDisconnect;
      await save();
      expect(vpn.canDisconnect, isFalse);
      if (mode == 'reset') {
        expect(vpn.status.phase, VpnPhase.error);
        expect(vpn.lastErrorCode, 'exclusions_unavailable');
      } else {
        expect(vpn.status.phase, VpnPhase.disconnected);
        expect(vpn.lastErrorCode, isNull);
        expect(await vpn.bridge.getExclusions(), isEmpty);
        report['reopenedPolicyEmpty'] = true;
      }
      await _tap(tester, find.byKey(const Key('settings-button')));
      await _tap(tester, find.text('Исключения приложений'));
      if (mode == 'reset') {
        await stage('reading corrupt policy');
        await _until(
          tester,
          () => find.text('Список недоступен').evaluate().isNotEmpty,
        );
        // Repeating a read must not seed an empty record behind the user's back.
        await _tap(tester, find.text('Повторить чтение'));
        await _until(
          tester,
          () => find.text('Список недоступен').evaluate().isNotEmpty,
        );
        await expectLater(
          vpn.bridge.getExclusions(),
          throwsA(
            isA<VpnFailure>().having(
              (e) => e.code,
              'code',
              'exclusions_unavailable',
            ),
          ),
        );
        report['readDidNotSilentlyReset'] = true;
        await snapshot('policy-corrupt');
        await stage('explicit reset');
        await _tap(tester, find.byKey(const Key('reset-exclusions')));
      }
      await _until(
        tester,
        () =>
            find.byType(CheckboxListTile).evaluate().isNotEmpty &&
            vpn.status.phase == VpnPhase.disconnected &&
            !vpn.commandPending,
      );
      expect(find.text('Список недоступен'), findsNothing);
      expect(find.byKey(const Key('reset-exclusions')), findsNothing);
      expect(vpn.lastErrorCode, isNull);
      expect(await vpn.bridge.getExclusions(), isEmpty);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((tile) => tile.value == false),
        isTrue,
      );
      report['policyEmpty'] = true;
      report['state'] = vpn.status.phase.name;
      report['errorCleared'] = true;
      await snapshot('policy-$mode');
      expect(tester.takeException(), isNull);
      report['passed'] = true;
      await stage('completed');
    } finally {
      await save();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('bounded_wait_expired');
    }
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
