// SPDX-License-Identifier: Apache-2.0
import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'dart_updates_types.dart';

/// The SDK enforces patch verification in a release built with its public key.
/// Engine availability alone is not evidence that a release is signed.
class ShorebirdDartUpdatesBackend implements DartUpdatesBackend {
  ShorebirdDartUpdatesBackend(this._updater, {required this.track}) {
    if (track != 'stable' && track != 'beta') {
      throw ArgumentError.value(track, 'track');
    }
  }
  final ShorebirdUpdater _updater;
  @override
  final String track;
  @override
  String? get disabledReason => null;

  @override
  Future<DartPatchSnapshot> read() async {
    try {
      if (!_updater.isAvailable) {
        return const DartPatchSnapshot(available: false);
      }
      final current = await _updater.readCurrentPatch();
      final next = await _updater.readNextPatch();
      if ((current != null && current.number <= 0) ||
          (next != null && next.number <= 0)) {
        throw const DartUpdatesFailure(DartUpdateError.readFailed);
      }
      return DartPatchSnapshot(
        available: true,
        current: current?.number,
        next: next?.number,
      );
    } catch (_) {
      throw const DartUpdatesFailure(DartUpdateError.readFailed);
    }
  }

  @override
  Future<DartUpdateCheck> check() async {
    try {
      if (!_updater.isAvailable) {
        return const DartUpdateCheck(
          DartUpdateStatus.unavailable,
          DartPatchSnapshot(available: false),
        );
      }
      final result = await _updater.checkForUpdate(track: UpdateTrack(track));
      if (result == UpdateStatus.unavailable) {
        return const DartUpdateCheck(
          DartUpdateStatus.unavailable,
          DartPatchSnapshot(available: false),
        );
      }
      // checkForUpdate can schedule rollback; read after the network call.
      final snapshot = await read();
      return DartUpdateCheck(switch (result) {
        UpdateStatus.upToDate => DartUpdateStatus.upToDate,
        UpdateStatus.outdated => DartUpdateStatus.outdated,
        UpdateStatus.restartRequired => DartUpdateStatus.restartRequired,
        UpdateStatus.unavailable => DartUpdateStatus.unavailable,
      }, snapshot);
    } on DartUpdatesFailure {
      rethrow;
    } catch (_) {
      throw const DartUpdatesFailure(DartUpdateError.checkFailed);
    }
  }

  @override
  Future<DartPatchSnapshot> download() async {
    try {
      if (!_updater.isAvailable) {
        return const DartPatchSnapshot(available: false);
      }
      await _updater.update(track: UpdateTrack(track));
      // Success can mean another updater is busy or no patch is available.
      // Only the engine's actual next patch confirms a prepared update.
      return await read();
    } on DartUpdatesFailure {
      rethrow;
    } on UpdateException catch (error) {
      throw DartUpdatesFailure(switch (error.reason) {
        UpdateFailureReason.noUpdate => DartUpdateError.noUpdate,
        UpdateFailureReason.downloadFailed => DartUpdateError.downloadFailed,
        UpdateFailureReason.installFailed => DartUpdateError.installFailed,
        UpdateFailureReason.unknown => DartUpdateError.operationFailed,
      });
    } catch (_) {
      throw const DartUpdatesFailure(DartUpdateError.operationFailed);
    }
  }
}
