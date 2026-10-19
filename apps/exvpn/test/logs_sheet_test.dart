// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:exvpn/services/client_logs.dart';
import 'package:exvpn/services/safe_diagnostics.dart';
import 'package:exvpn/src/logs_sheet.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'copy stays visible in a small window and exports a fresh report',
    (tester) async {
      tester.view.physicalSize = const Size(360, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AppController.demo();
      addTearDown(app.dispose);
      final logs = ClientLogs(controller: app);
      var core = '26.10.10';
      String snapshot() => safeDiagnostics(
        status: null,
        platform: 'windows',
        coreVersion: core,
        secureStorageAvailable: true,
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LogsSheet(logs: logs, diagnosticsBuilder: snapshot),
        ),
      );
      final copy = find.byKey(const ValueKey('client-logs-copy'));
      final before = tester.getRect(copy);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pump();
      expect(tester.getRect(copy), before);
      expect(before.bottom, lessThanOrEqualTo(300));
      core = '26.10.11';
      await tester.tap(copy);
      await tester.pumpAndSettle();
      final exported = jsonDecode(copied!) as Map;
      expect(exported['schema'], 2);
      expect((exported['diagnostics'] as Map)['coreVersion'], '26.10.11');
      await tester.tap(find.byKey(const ValueKey('client-logs-clear')));
      await tester.pump();
      expect(logs.eventCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      logs.dispose();
    },
  );

  testWidgets('clipboard failure shows only a safe short message', (
    tester,
  ) async {
    final app = AppController();
    addTearDown(app.dispose);
    final logs = ClientLogs(controller: app);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(
            code: 'private-code',
            message: 'PRIVATE-URL-SECRET',
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LogsSheet(
          logs: logs,
          diagnosticsBuilder: () => safeDiagnostics(
            status: null,
            platform: 'web',
            secureStorageAvailable: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('client-logs-copy')));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE-URL-SECRET'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    logs.dispose();
  });

  testWidgets('diagnostics builder errors cannot leak and disable copy', (
    tester,
  ) async {
    final app = AppController();
    addTearDown(app.dispose);
    final logs = ClientLogs(controller: app);
    await tester.pumpWidget(
      MaterialApp(
        home: LogsSheet(
          logs: logs,
          diagnosticsBuilder: () => throw StateError('PRIVATE-URL-SECRET'),
        ),
      ),
    );
    expect(find.textContaining('PRIVATE-URL-SECRET'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('client-logs-copy')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    logs.dispose();
  });
}
