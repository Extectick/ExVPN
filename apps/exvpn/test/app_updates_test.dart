// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:exvpn/services/app_updates.dart';
import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/full_updates_platform_native.dart';
import 'package:flutter_test/flutter_test.dart';

const offer = FullUpdateOffer(version: '0.1.0+22', sizeBytes: 100);

class FakeFullUpdates implements FullUpdatesBackend {
  @override
  bool supported = true;
  FullUpdateOffer? available = offer;
  Object? checkError, downloadError, handoffError;
  Completer<FullUpdateOffer?>? pendingCheck;
  Completer<FullUpdateOffer>? pendingDownload;
  FullUpdateProgressCallback? progress;
  int checks = 0, downloads = 0, handoffs = 0, restarts = 0, cancels = 0;
  bool disposed = false;
  FullUpdateHandoff handoffResult = FullUpdateHandoff.exitUi;
  Completer<FullUpdateHandoff>? pendingHandoff;
  @override
  Future<FullUpdateOffer?> check() async {
    checks++;
    if (checkError != null) throw checkError!;
    return pendingCheck == null ? available : await pendingCheck!.future;
  }

  @override
  Future<FullUpdateOffer> download(
    FullUpdateOffer selected, {
    required FullUpdateProgressCallback onProgress,
  }) async {
    downloads++;
    progress = onProgress;
    if (downloadError != null) throw downloadError!;
    return pendingDownload == null ? selected : await pendingDownload!.future;
  }

  @override
  Future<FullUpdateHandoff> handoff(FullUpdateOffer selected) async {
    handoffs++;
    if (handoffError != null) throw handoffError!;
    return pendingHandoff == null
        ? handoffResult
        : await pendingHandoff!.future;
  }

  @override
  Future<void> restartUi() async => restarts++;
  @override
  Future<void> cancel() async {
    cancels++;
    if (pendingCheck != null && !pendingCheck!.isCompleted) {
      pendingCheck!.completeError(AppUpdatesFailure('cancelled'));
    }
    if (pendingDownload != null && !pendingDownload!.isCompleted) {
      pendingDownload!.completeError(AppUpdatesFailure('cancelled'));
    }
  }

  @override
  void dispose() => disposed = true;
}

class FakePatchUpdates implements DartUpdatesBackend {
  @override
  String get track => 'beta';
  @override
  String? get disabledReason => null;
  DartPatchSnapshot saved = const DartPatchSnapshot(available: false);
  DartUpdateStatus status = DartUpdateStatus.outdated;
  Completer<DartPatchSnapshot>? pendingDownload;
  int reads = 0, checks = 0, downloads = 0;
  @override
  Future<DartPatchSnapshot> read() async {
    reads++;
    return saved;
  }

  @override
  Future<DartUpdateCheck> check() async {
    checks++;
    return DartUpdateCheck(status, saved);
  }

  @override
  Future<DartPatchSnapshot> download() async {
    downloads++;
    return pendingDownload == null ? saved : await pendingDownload!.future;
  }
}

void main() {
  group('app update arbitration and lifecycle', () {
    late FakeFullUpdates full;
    late FakePatchUpdates patch;
    late DartUpdatesController dart;
    late AppUpdatesController updates;
    setUp(() {
      full = FakeFullUpdates();
      patch = FakePatchUpdates();
      dart = DartUpdatesController(backend: patch);
      updates = AppUpdatesController(fullBackend: full, dartUpdates: dart);
    });
    tearDown(() {
      updates.dispose();
      dart.dispose();
    });

    test(
      'full release wins without starting a patch network operation',
      () async {
        patch.saved = const DartPatchSnapshot(available: true, next: 2);
        await dart.initialize();
        await updates.initialize();
        expect(updates.phase, AppUpdateStatePhase.available);
        expect(updates.kind, AppUpdateKind.full);
        expect(updates.availableVersion, offer.version);
        expect(patch.checks, 0);
        expect(updates.canRestart, false);
        await updates.download();
        expect(full.downloads, 1);
        expect(full.handoffs, 0);
        expect(patch.downloads, 0);
        expect(updates.phase, AppUpdateStatePhase.restartReady);
      },
    );

    test(
      'only actual byte progress is shown and repeated commands serialize',
      () async {
        await updates.initialize();
        full.pendingDownload = Completer<FullUpdateOffer>();
        final downloading = updates.download();
        expect(updates.progress, isNull);
        full.progress!(const FullUpdateProgress(received: 25, total: 100));
        expect(updates.progress, .25);
        full.progress!(const FullUpdateProgress(received: 10, total: 100));
        expect(updates.progress, .25);
        await updates.download();
        await updates.check();
        await updates.restart();
        expect(full.downloads, 1);
        expect(full.checks, 1);
        expect(full.handoffs, 0);
        full.pendingDownload!.complete(offer);
        await downloading;
        expect(updates.phase, AppUpdateStatePhase.restartReady);
      },
    );

    test(
      'download auto-restart requires caller barrier; blocked package retries',
      () async {
        updates.dispose();
        var safe = false;
        var barriers = 0;
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          beforeRestart: (kind, handoff) async {
            barriers++;
            expect(kind, AppUpdateKind.full);
            if (!safe) return false;
            await handoff();
            return true;
          },
        );
        await updates.initialize();
        await updates.download();
        expect(updates.phase, AppUpdateStatePhase.blocked);
        expect(updates.errorCode, 'restart_blocked');
        expect(full.handoffs, 0);
        safe = true;
        await updates.retry();
        expect(updates.phase, AppUpdateStatePhase.restarting);
        expect(full.handoffs, 1);
        expect(full.downloads, 1);
        expect(barriers, 2);
        await updates.restart();
        expect(full.handoffs, 1);
      },
    );

    test('callback cannot claim restart without invoking handoff', () async {
      updates.dispose();
      updates = AppUpdatesController(
        fullBackend: full,
        dartUpdates: dart,
        beforeRestart: (_, _) async => true,
      );
      await updates.initialize();
      await updates.download();
      expect(updates.phase, AppUpdateStatePhase.blocked);
      expect(full.handoffs, 0);
    });

    test('Android installer opening retains prepared retry without terminal handoff', () async {
      updates.dispose();
      full.handoffResult = FullUpdateHandoff.installerOpened;
      updates = AppUpdatesController(
        fullBackend: full,
        dartUpdates: dart,
        beforeRestart: (_, handoff) async {
          await handoff();
          return true;
        },
      );
      await updates.initialize();
      await updates.download();
      expect(updates.phase, AppUpdateStatePhase.restartReady);
      expect(updates.canRestart, isTrue);
      expect(updates.busy, isFalse);
      expect(full.handoffs, 1);
      expect(full.restarts, 0);
      await updates.restart();
      expect(full.handoffs, 2);
      expect(full.downloads, 1);
      expect(updates.phase, AppUpdateStatePhase.restartReady);
    });

    for (final code in [
      'install_permission_required',
      'install_cancelled',
      'install_failed',
    ]) {
      test(
        'Android $code is safe, unblocks and retries without downloading again',
        () async {
          updates.dispose();
          full.handoffResult = FullUpdateHandoff.installerOpened;
          full.handoffError = AppUpdatesFailure(code);
          updates = AppUpdatesController(
            fullBackend: full,
            dartUpdates: dart,
            beforeRestart: (_, handoff) async {
              await handoff();
              return true;
            },
          );
          await updates.initialize();
          await updates.download();
          expect(updates.phase, AppUpdateStatePhase.failed);
          expect(updates.errorCode, code);
          expect(updates.canRestart, isTrue);
          expect(updates.busy, isFalse);
          full.handoffError = null;
          await updates.retry();
          expect(updates.phase, AppUpdateStatePhase.restartReady);
          expect(full.handoffs, 2);
          expect(full.downloads, 1);
        },
      );
    }

    test(
      'a caller failure after Android installer opening never freezes the UI',
      () async {
        updates.dispose();
        full.handoffResult = FullUpdateHandoff.installerOpened;
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          beforeRestart: (_, handoff) async {
            await handoff();
            throw StateError('synthetic caller failure');
          },
        );
        await updates.initialize();
        await updates.download();
        expect(updates.phase, AppUpdateStatePhase.restartReady);
        expect(updates.canRestart, isTrue);
        expect(updates.busy, isFalse);
      },
    );

    test('invalidated Android package cache retries download with the trusted offer', () async {
      updates.dispose();
      full.handoffResult = FullUpdateHandoff.installerOpened;
      full.handoffError = AppUpdatesFailure(
        'integrity_failed',
        retryDownload: true,
      );
      updates = AppUpdatesController(
        fullBackend: full,
        dartUpdates: dart,
        beforeRestart: (_, handoff) async {
          await handoff();
          return true;
        },
      );
      await updates.initialize();
      await updates.download();
      expect(updates.phase, AppUpdateStatePhase.failed);
      expect(updates.errorCode, 'integrity_failed');
      expect(updates.availableVersion, offer.version);
      expect(updates.canDownload, isTrue);
      expect(updates.canRestart, isFalse);
      full.handoffError = null;
      await updates.retry();
      expect(full.checks, 1);
      expect(full.downloads, 2);
      expect(full.handoffs, 2);
      expect(updates.phase, AppUpdateStatePhase.restartReady);
    });

    test(
      'persistence failure before handoff retains prepared package',
      () async {
        updates.dispose();
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          beforeRestart: (_, _) async =>
              throw StateError('synthetic private path'),
        );
        await updates.initialize();
        await updates.download();
        expect(updates.phase, AppUpdateStatePhase.blocked);
        expect(updates.errorCode, 'restart_blocked');
        expect(updates.canRestart, true);
        expect(full.handoffs, 0);
      },
    );

    test(
      'helper handoff failure is safe and does not redownload on retry',
      () async {
        updates.dispose();
        full.handoffError = AppUpdatesFailure('integrity_failed');
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          beforeRestart: (_, handoff) async {
            await handoff();
            return true;
          },
        );
        await updates.initialize();
        await updates.download();
        expect(updates.phase, AppUpdateStatePhase.failed);
        expect(updates.errorCode, 'integrity_failed');
        full.handoffError = null;
        await updates.retry();
        expect(full.handoffs, 2);
        expect(full.downloads, 1);
      },
    );

    test(
      'absent feed is silent on startup and failure is visible on manual check',
      () async {
        full.checkError = AppUpdatesFailure('not_configured');
        await updates.initialize();
        expect(updates.phase, AppUpdateStatePhase.hidden);
        await updates.check();
        expect(updates.phase, AppUpdateStatePhase.failed);
        expect(updates.errorCode, 'not_configured');
        full.checkError = StateError('https://synthetic.invalid/private-token');
        await updates.check();
        expect(updates.errorCode, 'operation_failed');
      },
    );

    test(
      'previous install failure is visible on startup and retries a check',
      () async {
        patch.saved = const DartPatchSnapshot(available: true);
        full.checkError = AppUpdatesFailure('previous_install_failed');
        await updates.initialize();
        expect(updates.phase, AppUpdateStatePhase.failed);
        expect(updates.errorCode, 'previous_install_failed');
        expect(patch.checks, 0);
        full.checkError = null;
        await updates.retry();
        expect(updates.phase, AppUpdateStatePhase.available);
        expect(full.downloads, 0);
      },
    );

    test(
      'accepted handoff is never replayed if caller exit then fails',
      () async {
        updates.dispose();
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          beforeRestart: (_, handoff) async {
            await handoff();
            throw StateError('synthetic exit failure');
          },
        );
        await updates.initialize();
        await updates.download();
        expect(updates.phase, AppUpdateStatePhase.restarting);
        expect(updates.canRestart, false);
        await updates.retry();
        expect(full.handoffs, 1);
      },
    );

    test(
      'startup and resumes are bounded by a throttle, not a periodic poll',
      () async {
        updates.dispose();
        var clock = DateTime.utc(2026, 10, 18);
        full.available = null;
        updates = AppUpdatesController(
          fullBackend: full,
          dartUpdates: dart,
          now: () => clock,
        );
        await updates.initialize();
        await updates.initialize();
        await updates.onResume();
        expect(full.checks, 1);
        clock = clock.add(const Duration(minutes: 16));
        await updates.onResume();
        expect(full.checks, 2);
      },
    );

    test(
      'full cancel waits for owned command then allows a fresh check',
      () async {
        await updates.initialize();
        full.pendingDownload = Completer<FullUpdateOffer>();
        final downloading = updates.download();
        await updates.cancel();
        await downloading;
        expect(full.cancels, 1);
        expect(updates.busy, false);
        expect(updates.phase, AppUpdateStatePhase.hidden);
        await updates.check();
        expect(updates.phase, AppUpdateStatePhase.available);
      },
    );

    test('uncancellable SDK operation retains busy gate and indeterminate progress', () async {
      full.available = null;
      patch.saved = const DartPatchSnapshot(available: true);
      await updates.initialize();
      patch.pendingDownload = Completer<DartPatchSnapshot>();
      final downloading = updates.download();
      expect(updates.kind, AppUpdateKind.patch);
      expect(updates.progress, isNull);
      await updates.cancel();
      await updates.check();
      expect(updates.busy, true);
      expect(patch.downloads, 1);
      expect(full.cancels, 0);
      patch.pendingDownload!.complete(
        const DartPatchSnapshot(available: true, next: 3),
      );
      await downloading;
      expect(updates.phase, AppUpdateStatePhase.restartReady);
    });

    test('SDK return without prepared patch never claims a restart', () async {
      full.available = null;
      patch.saved = const DartPatchSnapshot(available: true);
      await updates.initialize();
      await updates.download();
      expect(updates.phase, AppUpdateStatePhase.failed);
      expect(updates.errorCode, 'patch_install_unconfirmed');
      expect(updates.canRestart, false);
    });

    test('legacy manual patch check and download update strip without auto restart', () async {
      full.available = null;
      patch.saved = const DartPatchSnapshot(available: true);
      await dart.initialize();
      await dart.check();
      expect(updates.phase, AppUpdateStatePhase.available);
      expect(updates.kind, AppUpdateKind.patch);
      patch.saved = const DartPatchSnapshot(available: true, next: 5);
      await dart.download();
      expect(updates.phase, AppUpdateStatePhase.restartReady);
      expect(full.restarts, 0);
    });

    test('legacy patch state never replaces offered full release', () async {
      await updates.initialize();
      patch.saved = const DartPatchSnapshot(available: true, next: 5);
      await dart.initialize();
      expect(updates.phase, AppUpdateStatePhase.available);
      expect(updates.kind, AppUpdateKind.full);
      expect(updates.availableVersion, offer.version);
    });

    test(
      'disposal suppresses late helper state and preserves shared Dart owner',
      () async {
        full.pendingCheck = Completer<FullUpdateOffer?>();
        var notifications = 0;
        updates.addListener(() => notifications++);
        final checking = updates.initialize();
        updates.dispose();
        final atDispose = notifications;
        full.pendingCheck!.complete(offer);
        await checking;
        await dart.initialize();
        expect(notifications, atDispose);
        expect(full.disposed, true);
        expect(patch.reads, 1);
      },
    );
  });

  group('native helper protocol', () {
    test('download progress uses validated actual bytes', () {
      final progress = <double?>[];
      final protocol = FullUpdateProtocol(
        'download',
        expectedVersion: offer.version,
        onProgress: (value) => progress.add(value.fraction),
      );
      protocol.addLine('{"type":"progress","received":20}');
      protocol.addLine('{"type":"progress","received":40,"total":100}');
      protocol.addLine(
        '{"type":"result","status":"ready","version":"0.1.0+22","sizeBytes":100}',
      );
      expect(progress, [null, .4]);
      expect(protocol.finish(exitCode: 0).offer!.version, offer.version);
    });

    for (final line in [
      '{"type":"progress","received":"20","total":100}',
      '{"type":"progress","received":20.0,"total":100}',
      '{"type":"progress","received":-1,"total":100}',
      '{"type":"progress","received":101,"total":100}',
      '{"type":"progress","received":1,"total":0}',
      '[]',
      'synthetic exception path',
    ]) {
      test('malformed progress or JSON is rejected: $line', () {
        final protocol = FullUpdateProtocol('download');
        expect(() => protocol.addLine(line), throwsA(isA<AppUpdatesFailure>()));
      });
    }

    test('progress may not decrease or change an established total', () {
      for (final next in [
        '{"type":"progress","received":19,"total":100}',
        '{"type":"progress","received":30,"total":200}',
        '{"type":"progress","received":30}',
      ]) {
        final protocol = FullUpdateProtocol('download');
        protocol.addLine('{"type":"progress","received":20,"total":100}');
        expect(() => protocol.addLine(next), throwsA(isA<AppUpdatesFailure>()));
      }
    });

    test(
      'download must acknowledge exact offered version and ready status',
      () {
        for (final response in [
          {'type': 'result', 'status': 'ready', 'version': '0.1.0+21'},
          {'type': 'result', 'status': 'ready', 'version': 22},
          {'type': 'result', 'status': 'ready'},
          {'type': 'result', 'status': 'available', 'version': offer.version},
          {'type': 'result', 'status': 'ready', 'version': 'synthetic/private'},
          {
            'type': 'result',
            'status': 'ready',
            'version': offer.version,
            'sizeBytes': '100',
          },
        ]) {
          final protocol = FullUpdateProtocol(
            'download',
            expectedVersion: offer.version,
          );
          protocol.addLine(jsonEncode(response));
          expect(
            () => protocol.finish(exitCode: 0),
            throwsA(isA<AppUpdatesFailure>()),
          );
        }
      },
    );

    test(
      'missing, duplicate, contradictory and nonzero replies are failures',
      () {
        final missing = FullUpdateProtocol('check');
        expect(
          () => missing.finish(exitCode: 0),
          throwsA(isA<AppUpdatesFailure>()),
        );
        final duplicate = FullUpdateProtocol('check');
        duplicate.addLine('{"type":"result","status":"upToDate"}');
        expect(
          () => duplicate.addLine('{"type":"result","status":"upToDate"}'),
          throwsA(isA<AppUpdatesFailure>()),
        );
        expect(
          () => duplicate.finish(exitCode: 1),
          throwsA(isA<AppUpdatesFailure>()),
        );
        final wrong = FullUpdateProtocol('handoff');
        wrong.addLine(
          '{"type":"result","status":"ready","version":"0.1.0+22"}',
        );
        expect(
          () => wrong.finish(exitCode: 0),
          throwsA(isA<AppUpdatesFailure>()),
        );
      },
    );

    test('only known diagnostic codes escape the process boundary', () {
      final protocol = FullUpdateProtocol('check');
      protocol.addLine(
        '{"type":"result","status":"error","errorCode":"https://synthetic.invalid/token"}',
      );
      expect(
        () => protocol.finish(exitCode: 1),
        throwsA(
          isA<AppUpdatesFailure>().having(
            (failure) => failure.code,
            'code',
            'operation_failed',
          ),
        ),
      );
      expect(isFullUpdateIdentity('0.1.0+22'), true);
      for (final version in [
        '0.1.0+0',
        '0.1.0+022',
        '0.1.0+2147483648',
        '../x+22',
        '0.01.0+22',
      ]) {
        expect(isFullUpdateIdentity(version), false);
      }
    });

    test('installer acceptance must identify the exact staged release', () {
      for (final version in <String?>[null, '0.1.0+21']) {
        final protocol = FullUpdateProtocol(
          'handoff',
          expectedVersion: offer.version,
        );
        protocol.addLine(
          jsonEncode({
            'type': 'result',
            'status': 'accepted',
            'version': ?version,
          }),
        );
        expect(
          () => protocol.finish(exitCode: 0),
          throwsA(isA<AppUpdatesFailure>()),
        );
      }
      final restart = FullUpdateProtocol('restart-ui');
      restart.addLine('{"type":"result","status":"accepted"}');
      expect(restart.finish(exitCode: 0).status, 'accepted');
    });
  });
}
