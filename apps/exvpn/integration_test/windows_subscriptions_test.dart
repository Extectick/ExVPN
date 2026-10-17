// SPDX-License-Identifier: Apache-2.0
// Guest-only E3-008 entry point. Real app/journal/DPAPI; no VPN or HTTP.
// The protected launcher owns staging, the two processes, and final directory
// cleanup. Only the storage directory is overridden; encryption is not mocked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:exvpn/build_identity.dart';
import 'package:exvpn/main.dart';
import 'package:exvpn/services/data_updates.dart';
import 'package:exvpn/services/subscription_store.dart';
import 'package:exvpn/services/windows_secure_store.dart';
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _input = r'C:\ExVPN-App-QA';
const _outputRoot = r'C:\ExVPN-Lifecycle-QA-Results';
const _dataRoot = r'C:\ProgramData\ExVPN Subscription QA';
const _executable = r'C:\Program Files\ExVPN UI QA\exvpn.exe';
const _groupName = 'QA Subscription';
const _host = 'qa-subscriptions.invalid';
const _originalNames = ['QA Original A', 'QA Original B', 'QA Original C'];
const _replacementName = 'QA Replacement';

String _profile(int number, String name) =>
    'vless://00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}'
    '@$_host:443?security=tls#${Uri.encodeComponent(name)}';

final class _Run {
  const _Run(this.id, this.phase, this.previous);
  final String id;
  final String phase;
  final Map<String, dynamic>? previous;
  String get output => '$_outputRoot\\$id';
  String get data => '$_dataRoot\\$id';
  String get reportPath => '$output\\subscriptions-$phase.json';
}

Future<Map<String, dynamic>> _readJson(String path, {int limit = 65536}) async {
  final file = File(path);
  if (await file.length() > limit) throw const FormatException();
  final bytes = await file.readAsBytes();
  if (bytes.length > limit) throw const FormatException();
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

Future<_Run> _readRun() async {
  if (!Platform.isWindows ||
      Platform.resolvedExecutable.toLowerCase() != _executable.toLowerCase()) {
    throw const FormatException();
  }
  final marker = await _readJson(
    '$_input\\sandbox-bundle.json',
    limit: 1024 * 1024,
  );
  final id = marker['runId'];
  final phase = marker['subscriptionPhase'];
  final forbiddenHost = marker['forbiddenHost'];
  final computer = Platform.environment['COMPUTERNAME'];
  if (id is! String ||
      !RegExp(r'^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$').hasMatch(id) ||
      id == '00000000-0000-0000-0000-000000000000' ||
      !['edit', 'reopen'].contains(phase) ||
      forbiddenHost is! String ||
      forbiddenHost.isEmpty ||
      computer == null ||
      computer.isEmpty ||
      forbiddenHost.toLowerCase() == computer.toLowerCase() ||
      marker['subscriptionUi'] != true ||
      marker['unelevated'] != true ||
      marker['build'] is! int ||
      marker['build'] != appBuild ||
      marker['faults'] != false ||
      marker['providerMatrix'] != false ||
      marker['networkRecovery'] != false ||
      marker['transportCycles'] != 0 ||
      marker['policyRecovery'] != null) {
    throw const FormatException();
  }
  final output = '$_outputRoot\\$id';
  final data = '$_dataRoot\\$id';
  if (!await Directory(output).exists() ||
      await FileSystemEntity.type(data, followLinks: false) !=
          FileSystemEntityType.directory ||
      await File('$output\\subscriptions-$phase.json').exists()) {
    throw const FormatException();
  }
  Map<String, dynamic>? previous;
  if (phase == 'edit') {
    // A reused data directory must not silently overwrite another attempt.
    if (await Directory('$data\\secure-subscriptions').exists()) {
      throw const FormatException();
    }
  } else {
    previous = await _readJson('$output\\subscriptions-edit.json');
    if (previous['runId'] != id ||
        previous['phase'] != 'edit' ||
        previous['version'] != appVersionLabel ||
        previous['frameworkPassed'] != true ||
        previous['passed'] != true ||
        previous['awaitingReopen'] != true ||
        previous['storagePathOverride'] != true ||
        previous['processId'] is! int ||
        previous['processId'] == pid ||
        previous['processId'] <= 0 ||
        !await Directory('$data\\secure-subscriptions').exists()) {
      throw const FormatException();
    }
  }
  return _Run(id, phase as String, previous);
}

Future<void> main() async {
  late final _Run run;
  try {
    run = await _readRun();
  } catch (_) {
    // No output path or protected storage is touched after invalid markers.
    exit(78);
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'format': 1,
    'runId': run.id,
    'phase': run.phase,
    'version': appVersionLabel,
    'processId': pid,
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
    'storageBackend': 'windows-current-user-dpapi',
    'storagePathOverride': true,
    'defaultStorageLocationTested': false,
    'syntheticInputOnly': true,
    'vpnInitialized': false,
    'vpnActionsPerformed': false,
    'httpRequestsPerformed': false,
    'updatesBackendDisabledForQa': true,
    'nativeImeTested': false,
    'computerUse': false,
    'passed': false,
  };
  Future<void> save() => File(run.reportPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      report['frameworkPassed'] = passed;
      report['finishedUtc'] = DateTime.now().toUtc().toIso8601String();
      try {
        await save();
      } catch (_) {
        exit(74);
      }
      exit(passed && report['passed'] == true ? 0 : 1);
    }),
  );
  testWidgets('partial subscription decisions and DPAPI: ${run.phase}', (
    tester,
  ) async {
    final boundary = GlobalKey();
    AppController? controller;
    var mountedApp = false;
    final backend = WindowsSecureKeyValueStore.forTesting(Directory(run.data));
    final store = SubscriptionStore.forTesting(backend);
    Future<void> stage(String name) async {
      report['stage'] = name;
      await save();
    }

    Future<void> snapshot(String name) async {
      // Captures are taken only after closing the raw-input dialog. All visible
      // labels are synthetic, and a review contains fixed codes/indices only.
      expect(find.byType(ImportDialog), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${run.output}\\subscriptions-$name.png')
            .writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    }

    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    try {
      await stage('checking-launch');
      final launch = await _readJson(
        '${run.output}\\subscriptions-${run.phase}-launch-report.json',
      );
      expect(launch['runId'], run.id);
      expect(launch['subscriptionPhase'], run.phase);
      expect(launch['processId'], pid);
      expect(launch['administratorToken'], isFalse);
      expect(launch['elevated'], isFalse);
      expect(launch['mediumIntegrity'], isTrue);
      expect(launch['adminPrivilegesAbsent'], isTrue);
      expect(launch['sameInstallerOwner'], isTrue);
      expect(launch['processTokenVerified'], isTrue);
      expect(launch['privilegedAccessDenied'], isTrue);
      report['ordinaryUserTokenTested'] = true;
      final executableHash = sha256
          .convert(await File(Platform.resolvedExecutable).readAsBytes())
          .toString();
      report['executableSha256'] = executableHash;
      if (run.previous != null) {
        expect(executableHash, run.previous!['executableSha256']);
        report['differentProcessFromEdit'] = true;
      }
      await stage('loading-dpapi');
      controller = await store.load();
      expect(store.recovered, isFalse);
      final app = controller;
      if (run.phase == 'edit') {
        expect(app.groups, isEmpty);
      } else {
        _expectReplacement(app);
        expect(_snapshotDigest(app), run.previous!['snapshotSha256']);
        report['coldRestoreMatched'] = true;
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ExVpnApp(
            controller: app,
            store: store,
            updates: DataUpdatesController(
              vpn: null,
              backend: DisabledDataUpdatesBackend('qa_scope'),
            ),
          ),
        ),
      );
      mountedApp = true;
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<HomeScreen>(find.byType(HomeScreen)).vpn, isNull);
      expect(find.text('Не подключено'), findsOneWidget);

      if (run.phase == 'edit') {
        await stage('adding-synthetic-list');
        await _tap(tester, find.byKey(const Key('add-button')));
        await _tap(tester, find.text('Текст'));
        await tester.enterText(
          find.byKey(const Key('subscription-name')),
          _groupName,
        );
        await tester.enterText(
          find.byKey(const Key('subscription-input')),
          [
            for (var index = 0; index < _originalNames.length; index++)
              _profile(index + 1, _originalNames[index]),
          ].join('\n'),
        );
        await _tap(tester, find.byKey(const Key('import-submit')));
        await _until(
          tester,
          () => find.byType(ImportDialog).evaluate().isEmpty,
        );
        expect(app.groups.single.servers, hasLength(3));
        final group = app.groups.single;
        await _tap(
          tester,
          find.byKey(ValueKey('server-${group.id}-${group.servers.last.id}')),
        );
        await _flush(tester);
        final selectedBefore = app.selectedServerId;
        final idsBefore = group.servers.map((server) => server.id).toList();
        expect(app.selectedServer!.name, _originalNames.last);
        await snapshot('original');

        await stage('manual-partial-replacement');
        await _tap(tester, find.byKey(const Key('refresh-button')));
        await _tap(tester, find.widgetWithText(SimpleDialogOption, _groupName));
        await _tap(tester, find.text('Текст'));
        await tester.enterText(
          find.byKey(const Key('subscription-input')),
          '${_profile(4, _replacementName)}\n'
          'unknown://QA-CANARY-CREDENTIAL@$_host/QA-CANARY-TOKEN\n'
          'vless://bad',
        );
        await _tap(tester, find.byKey(const Key('import-submit')));
        await _until(
          tester,
          () => find.text('Обновить часть подписки?').evaluate().isNotEmpty,
        );
        _expectReview();
        expect(app.groups.single.servers.map((server) => server.id), idsBefore);
        expect(app.selectedServerId, selectedBefore);
        await _tap(tester, find.byKey(const Key('keep-subscription')));
        await _until(
          tester,
          () => find.text('Обновить часть подписки?').evaluate().isEmpty,
        );
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(app.groups.single.servers.map((server) => server.id), idsBefore);
        expect(app.selectedServerId, selectedBefore);
        expect(app.pendingUpdate(group.id), isNotNull);
        await _flush(tester);
        final canceled = await store.load();
        try {
          expect(
            canceled.groups.single.servers.map((server) => server.id),
            idsBefore,
          );
          expect(canceled.selectedServerId, selectedBefore);
          expect(canceled.pendingUpdate(group.id), isNull);
        } finally {
          canceled.dispose();
        }
        report['cancelPreservedWorkingListAndSelection'] = true;
        report['cancelPersistedWorkingList'] = true;
        await _tap(
          tester,
          find.descendant(
            of: find.byType(ImportDialog),
            matching: find.widgetWithText(TextButton, 'Отмена'),
          ),
        );
        await snapshot('canceled');

        await stage('confirming-displayed-candidate');
        await _tap(
          tester,
          find.byKey(ValueKey('subscription-issues-${group.id}')),
        );
        _expectReview();
        expect(find.textContaining('QA-CANARY'), findsNothing);
        expect(find.textContaining(_host), findsNothing);
        await snapshot('review');
        await _tap(
          tester,
          find.byKey(const Key('accept-partial-subscription')),
        );
        await _until(tester, () => app.groups.single.servers.length == 1);
        _expectReplacement(app);
        await _flush(tester);
        report['explicitReplacementApplied'] = true;
        report['safeIssueIndices'] = [2, 3];
        report['safeIssueCodes'] = ['unsupportedProtocol', 'invalidProfile'];
        await snapshot('accepted');
      } else {
        await snapshot('reopened');
        expect(find.text(_replacementName), findsWidgets);
        expect(find.textContaining('Замечания к подписке: 2'), findsOneWidget);
      }

      await stage('checking-durable-replacement');
      await _flush(tester);
      final persisted = await store.load();
      try {
        _expectReplacement(persisted);
        expect(_snapshotDigest(persisted), _snapshotDigest(app));
      } finally {
        persisted.dispose();
      }
      final cipher = await File(
        '${run.data}\\secure-subscriptions\\${SubscriptionStore.currentKey}.dpapi',
      ).readAsBytes();
      expect(cipher, isNotEmpty);
      // Each canary is known to be present in the accepted plaintext snapshot.
      final binaryText = latin1.decode(cipher);
      for (final canary in [_host, _groupName, _replacementName]) {
        expect(binaryText.contains(canary), isFalse);
      }
      expect(await backend.read(SubscriptionStore.pendingKey), isNull);
      report['snapshotSha256'] = _snapshotDigest(app);
      report['ciphertextSha256'] = sha256.convert(cipher).toString();
      report['ciphertextBytes'] = cipher.length;
      report['storedPlaintextCanariesAbsent'] = true;
      report['pendingJournalAbsent'] = true;
      if (run.phase == 'edit') {
        report['awaitingReopen'] = true;
      } else {
        expect(report['ciphertextSha256'], run.previous!['ciphertextSha256']);
        await stage('removing-owned-group');
        await _tap(tester, find.byKey(const Key('settings-button')));
        await _tap(tester, find.byTooltip('Удалить $_groupName'));
        await _tap(tester, find.widgetWithText(FilledButton, 'Удалить'));
        await _until(tester, () => app.groups.isEmpty);
        await _flush(tester);
        final cleaned = await store.load();
        try {
          expect(cleaned.groups, isEmpty);
          expect(cleaned.selectedServerId, isNull);
        } finally {
          cleaned.dispose();
        }
        expect(await backend.read(SubscriptionStore.pendingKey), isNull);
        report['ownedGroupsDeletedThroughUi'] = true;
        report['emptyStatePersisted'] = true;
        report['awaitingReopen'] = false;
        await snapshot('cleaned');
      }
      expect(tester.takeException(), isNull);
      report['passed'] = true;
      await stage('completed');
    } catch (_) {
      report['failureCode'] = 'subscription_ui_check_failed';
      rethrow;
    } finally {
      if (mountedApp) {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        controller?.dispose();
      }
      await save();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

void _expectReview() {
  expect(find.textContaining('Сейчас подключений: 3.'), findsOneWidget);
  expect(find.textContaining('поддерживаются: 1.'), findsOneWidget);
  expect(
    find.text('Запись 2: Протокол пока не поддерживается.'),
    findsOneWidget,
  );
  expect(
    find.text('Запись 3: Некорректные или неполные параметры подключения.'),
    findsOneWidget,
  );
}

void _expectReplacement(AppController controller) {
  expect(controller.groups, hasLength(1));
  final group = controller.groups.single;
  expect(group.name, _groupName);
  expect(group.servers, hasLength(1));
  expect(group.servers.single.name, _replacementName);
  expect(group.sourceUrl, isNull);
  expect(group.isDemo, isFalse);
  expect(group.issues.map((issue) => issue.index), [2, 3]);
  expect(group.issues.map((issue) => issue.code), [
    ImportIssueCode.unsupportedProtocol,
    ImportIssueCode.invalidProfile,
  ]);
  expect(controller.selectedGroupId, group.id);
  expect(controller.selectedServerId, group.servers.single.id);
  expect(controller.pendingUpdate(group.id), isNull);
}

String _snapshotDigest(AppController controller) => sha256
    .convert(utf8.encode(jsonEncode(controller.exportSnapshot())))
    .toString();

Future<void> _flush(WidgetTester tester) async {
  final home = tester.widget<HomeScreen>(
    find.byType(HomeScreen, skipOffstage: false),
  );
  expect(home.persistence, isNotNull);
  await home.persistence!.flush();
  await tester.pump();
  expect(home.persistence!.error, isNull);
  expect(home.persistence!.pending, isFalse);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('bounded_subscription_wait_expired');
    }
    await tester.pump(const Duration(milliseconds: 150));
  }
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
}
