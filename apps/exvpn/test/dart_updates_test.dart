// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:exvpn/services/dart_updates.dart';
import 'package:exvpn/services/dart_updates_platform_native.dart';
import 'package:exvpn/services/dart_updates_shorebird.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class FakeDartUpdates implements DartUpdatesBackend {
  @override
  String track = 'beta';
  @override
  String? disabledReason;
  DartPatchSnapshot saved = const DartPatchSnapshot(available: true);
  DartUpdateStatus nextStatus = DartUpdateStatus.outdated;
  Object? readError, checkError, downloadError;
  Future<DartPatchSnapshot>? pendingDownload;
  Future<DartUpdateCheck>? pendingCheck;
  int reads = 0, checks = 0, downloads = 0;
  @override
  Future<DartPatchSnapshot> read() async {
    reads++;
    if (readError != null) throw readError!;
    return saved;
  }

  @override
  Future<DartUpdateCheck> check() async {
    checks++;
    if (checkError != null) throw checkError!;
    return await (pendingCheck ??
        Future.value(DartUpdateCheck(nextStatus, saved)));
  }

  @override
  Future<DartPatchSnapshot> download() async {
    downloads++;
    if (downloadError != null) throw downloadError!;
    return await (pendingDownload ?? Future.value(saved));
  }
}

class FakeShorebirdUpdater implements ShorebirdUpdater {
  @override
  bool isAvailable = true;
  Patch? current, next;
  UpdateStatus result = UpdateStatus.outdated;
  Object? readError, checkError, updateError;
  int checks = 0, downloads = 0, reads = 0;
  String? checkTrack, updateTrack;
  void Function()? onCheck, onUpdate;
  @override
  Future<Patch?> readCurrentPatch() async {
    reads++;
    if (readError != null) throw readError!;
    return current;
  }

  @override
  Future<Patch?> readNextPatch() async => next;
  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async {
    checks++;
    checkTrack = track?.name;
    onCheck?.call();
    if (checkError != null) throw checkError!;
    return result;
  }

  @override
  Future<void> update({UpdateTrack? track}) async {
    downloads++;
    updateTrack = track?.name;
    onUpdate?.call();
    if (updateError != null) throw updateError!;
  }
}

void main() {
  test('ordinary Flutter engine reports unavailable through the real isolated adapter', () async {
    final backend = createDartUpdatesBackend('beta');
    final result = await backend.read();
    expect(result.available, false);
    expect(result.restartRequired, false);
  });

  group('controller', () {
    late FakeDartUpdates backend;
    late DartUpdatesController controller;
    setUp(() {
      backend = FakeDartUpdates();
      controller = DartUpdatesController(backend: backend);
    });
    tearDown(() => controller.dispose());

    test(
      'initial identity read is local, distinguishes base from unavailable',
      () async {
        expect(controller.snapshot, isNull);
        expect(controller.canCheck, false);
        await controller.initialize();
        await controller.initialize();
        expect(backend.reads, 1);
        expect(backend.checks, 0);
        expect(controller.available, true);
        expect(controller.snapshot!.current, isNull);
        expect(controller.status, isNull); // Not a network freshness claim.
        backend.saved = const DartPatchSnapshot(available: false);
        await controller.refresh();
        await controller.check();
        await controller.download();
        expect(controller.available, false);
        expect(controller.status, DartUpdateStatus.unavailable);
        expect(backend.checks, 0);
        expect(backend.downloads, 0);
      },
    );

    test('read failure is unknown, not patch zero, and can recover', () async {
      backend.readError = const DartUpdatesFailure(DartUpdateError.readFailed);
      await controller.initialize();
      expect(controller.snapshot, isNull);
      expect(controller.error, DartUpdateError.readFailed);
      expect(controller.canCheck, false);
      backend.readError = null;
      backend.saved = const DartPatchSnapshot(
        available: true,
        current: 3,
        next: 3,
      );
      await controller.refresh();
      expect(controller.snapshot!.current, 3);
      expect(controller.error, isNull);
    });

    test(
      'only a checked available patch can download; current remains active',
      () async {
        await controller.initialize();
        await controller.download();
        expect(backend.downloads, 0);
        await controller.check();
        expect(controller.canDownload, true);
        backend.saved = const DartPatchSnapshot(available: true, next: 2);
        await controller.download();
        expect(controller.snapshot!.current, isNull);
        expect(controller.snapshot!.next, 2);
        expect(controller.restartRequired, true);
        expect(controller.canDownload, false);
        expect(backend.downloads, 1);
      },
    );

    for (final target in <int?>[null, 2]) {
      test(
        'rollback from patch 4 to $target is pending until process restart',
        () async {
          backend.saved = const DartPatchSnapshot(
            available: true,
            current: 4,
            next: 4,
          );
          await controller.initialize();
          backend.saved = DartPatchSnapshot(
            available: true,
            current: 4,
            next: target,
          );
          backend.nextStatus = DartUpdateStatus.restartRequired;
          await controller.check();
          expect(controller.snapshot!.current, 4);
          expect(controller.snapshot!.next, target);
          expect(controller.restartRequired, true);
          expect(controller.canDownload, false);
        },
      );
    }

    test(
      'check failure reconciles a rollback that already reached the engine',
      () async {
        backend.saved = const DartPatchSnapshot(
          available: true,
          current: 5,
          next: 5,
        );
        await controller.initialize();
        backend.saved = const DartPatchSnapshot(available: true, current: 5);
        backend.checkError = StateError('sensitive server response');
        await controller.check();
        expect(controller.restartRequired, true);
        expect(controller.snapshot!.current, 5);
        expect(controller.error, DartUpdateError.operationFailed);
        expect(
          dartUpdatesErrorText(controller.error!),
          isNot(contains('sensitive')),
        );
        expect(backend.checks, 1);
        expect(backend.reads, 2);
      },
    );

    test(
      'failed reconciliation invalidates old next patch and disables actions',
      () async {
        backend.saved = const DartPatchSnapshot(
          available: true,
          current: 4,
          next: 7,
        );
        await controller.initialize();
        backend.checkError = const DartUpdatesFailure(
          DartUpdateError.checkFailed,
        );
        backend.readError = StateError('unreadable');
        await controller.check();
        expect(controller.snapshot, isNull);
        expect(controller.status, isNull);
        expect(controller.restartRequired, false);
        expect(controller.canDownload, false);
        expect(controller.canCheck, false);
        expect(controller.error, DartUpdateError.checkFailed);
      },
    );

    test(
      'SDK update success without next patch never claims a downloaded patch',
      () async {
        await controller.initialize();
        await controller.check();
        await controller.download();
        expect(controller.status, isNull);
        expect(controller.downloadUnconfirmed, true);
        expect(controller.restartRequired, false);
        expect(controller.canDownload, false);
        await controller.download();
        expect(backend.downloads, 1);
      },
    );

    test(
      'failed download preserves an independently prepared next patch',
      () async {
        await controller.initialize();
        await controller.check();
        backend.saved = const DartPatchSnapshot(available: true, next: 2);
        backend.downloadError = const DartUpdatesFailure(
          DartUpdateError.installFailed,
        );
        await controller.download();
        expect(controller.error, DartUpdateError.installFailed);
        expect(controller.restartRequired, true);
        expect(controller.snapshot!.next, 2);
        expect(controller.canDownload, false);
      },
    );

    test('duplicate check/read/download commands do not overlap', () async {
      await controller.initialize();
      final done = Completer<DartUpdateCheck>();
      backend.pendingCheck = done.future;
      final checking = controller.check();
      await controller.check();
      await controller.refresh();
      await controller.download();
      expect(backend.checks, 1);
      expect(backend.reads, 1);
      expect(backend.downloads, 0);
      done.complete(DartUpdateCheck(DartUpdateStatus.upToDate, backend.saved));
      await checking;
      expect(controller.busy, false);
      expect(controller.status, DartUpdateStatus.upToDate);
    });

    testWidgets(
      'slow native operation keeps exclusive ownership until completion',
      (tester) async {
        await controller.initialize();
        await controller.check();
        final done = Completer<DartPatchSnapshot>();
        backend.pendingDownload = done.future;
        final downloading = controller.download();
        await tester.pump(const Duration(seconds: 31));
        expect(controller.slow, true);
        expect(controller.busy, true);
        await controller.check();
        await controller.download();
        expect(backend.downloads, 1);
        expect(backend.checks, 1);
        done.complete(const DartPatchSnapshot(available: true, next: 1));
        await downloading;
        expect(controller.busy, false);
        expect(controller.restartRequired, true);
      },
    );

    test(
      'disposal suppresses late state and does not start recovery reads',
      () async {
        await controller.initialize();
        final done = Completer<DartUpdateCheck>();
        backend.pendingCheck = done.future;
        final old = controller;
        final checking = old.check();
        old.dispose();
        controller = DartUpdatesController(
          backend: const DisabledDartUpdatesBackend(),
        );
        done.completeError(StateError('late private response'));
        await checking;
        expect(backend.reads, 1);
        expect(backend.checks, 1);
        expect(backend.downloads, 0);
      },
    );

    test('local refresh invalidates an old download offer', () async {
      await controller.initialize();
      await controller.check();
      expect(controller.canDownload, true);
      await controller.refresh();
      await controller.download();
      expect(controller.canDownload, false);
      expect(backend.downloads, 0);
    });
  });

  group('official SDK adapter', () {
    for (final track in ['beta', 'stable']) {
      test(
        '$track is fixed for both network calls; metadata read is local',
        () async {
          final sdk = FakeShorebirdUpdater();
          final backend = ShorebirdDartUpdatesBackend(sdk, track: track);
          final identity = await backend.read();
          expect(identity.available, true);
          expect(sdk.checks, 0);
          expect((await backend.check()).status, DartUpdateStatus.outdated);
          sdk.onUpdate = () => sdk.next = const Patch(number: 4);
          final downloaded = await backend.download();
          expect(sdk.checkTrack, track);
          expect(sdk.updateTrack, track);
          expect(downloaded.current, isNull);
          expect(downloaded.next, 4);
        },
      );
    }

    test('unavailable engine never returns base as available or performs network IO', () async {
      final sdk = FakeShorebirdUpdater()..isAvailable = false;
      final backend = ShorebirdDartUpdatesBackend(sdk, track: 'stable');
      expect((await backend.read()).available, false);
      expect((await backend.check()).status, DartUpdateStatus.unavailable);
      expect((await backend.download()).available, false);
      expect(sdk.reads + sdk.checks + sdk.downloads, 0);
    });

    test('rollback is read after check, and install/no-update success is not guessed', () async {
      final sdk = FakeShorebirdUpdater()
        ..current = const Patch(number: 9)
        ..next = const Patch(number: 9)
        ..result = UpdateStatus.restartRequired;
      sdk.onCheck = () => sdk.next = null;
      final backend = ShorebirdDartUpdatesBackend(sdk, track: 'beta');
      expect((await backend.check()).snapshot.restartRequired, true);
      sdk.current = null;
      final noUpdate = await backend.download();
      expect(noUpdate.restartRequired, false);
      expect(noUpdate.next, isNull);
    });

    for (final pair in {
      UpdateFailureReason.noUpdate: DartUpdateError.noUpdate,
      UpdateFailureReason.downloadFailed: DartUpdateError.downloadFailed,
      UpdateFailureReason.installFailed: DartUpdateError.installFailed,
      UpdateFailureReason.unknown: DartUpdateError.operationFailed,
    }.entries) {
      test('${pair.key.name} returns only a safe typed error', () async {
        final sdk = FakeShorebirdUpdater()
          ..updateError = UpdateException(
            message: 'private.invalid/token',
            reason: pair.key,
          );
        final backend = ShorebirdDartUpdatesBackend(sdk, track: 'stable');
        await expectLater(
          backend.download(),
          throwsA(
            isA<DartUpdatesFailure>().having((e) => e.code, 'code', pair.value),
          ),
        );
        expect(
          dartUpdatesErrorText(pair.value),
          isNot(contains('private.invalid')),
        );
      });
    }

    test(
      'metadata read failure and invalid patch number are not base release',
      () async {
        final sdk = FakeShorebirdUpdater()
          ..readError = const ReadPatchException(message: 'private path');
        final backend = ShorebirdDartUpdatesBackend(sdk, track: 'beta');
        await expectLater(
          backend.check(),
          throwsA(
            isA<DartUpdatesFailure>().having(
              (e) => e.code,
              'code',
              DartUpdateError.readFailed,
            ),
          ),
        );
        sdk.readError = null;
        sdk.next = const Patch(number: -1);
        await expectLater(backend.read(), throwsA(isA<DartUpdatesFailure>()));
      },
    );

    test('invalid track cannot silently fall back to stable', () async {
      expect(
        () => ShorebirdDartUpdatesBackend(
          FakeShorebirdUpdater(),
          track: 'provider-controlled',
        ),
        throwsArgumentError,
      );
      final backend = createDartUpdatesBackend('provider-controlled');
      expect(backend.disabledReason, 'invalid_configuration');
      expect((await backend.read()).available, false);
    });
  });
}
