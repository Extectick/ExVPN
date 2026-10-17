// SPDX-License-Identifier: Apache-2.0
enum DartUpdateStatus { upToDate, outdated, restartRequired, unavailable }

enum DartUpdateError {
  readFailed,
  checkFailed,
  downloadFailed,
  installFailed,
  noUpdate,
  operationFailed,
}

class DartUpdatesFailure implements Exception {
  const DartUpdatesFailure(this.code);
  final DartUpdateError code;
}

/// A null patch means the base release only when the engine is available and
/// both reads succeeded. A null next patch can also be a scheduled rollback.
class DartPatchSnapshot {
  const DartPatchSnapshot({required this.available, this.current, this.next});
  final bool available;
  final int? current;
  final int? next;
  bool get restartRequired => available && current != next;
}

class DartUpdateCheck {
  const DartUpdateCheck(this.status, this.snapshot);
  final DartUpdateStatus status;
  final DartPatchSnapshot snapshot;
}

abstract interface class DartUpdatesBackend {
  String get track;
  String? get disabledReason;
  Future<DartPatchSnapshot> read();
  Future<DartUpdateCheck> check();
  Future<DartPatchSnapshot> download();
}

class DisabledDartUpdatesBackend implements DartUpdatesBackend {
  const DisabledDartUpdatesBackend({
    this.disabledReason = 'unsupported_platform',
    this.track = 'stable',
  });
  @override
  final String? disabledReason;
  @override
  final String track;
  @override
  Future<DartPatchSnapshot> read() async =>
      const DartPatchSnapshot(available: false);
  @override
  Future<DartUpdateCheck> check() async =>
      DartUpdateCheck(DartUpdateStatus.unavailable, await read());
  @override
  Future<DartPatchSnapshot> download() => read();
}
