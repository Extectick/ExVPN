// SPDX-License-Identifier: Apache-2.0
enum AppUpdateStatePhase {
  hidden,
  checking,
  available,
  downloading,
  restartReady,
  restarting,
  failed,
  blocked,
}

enum AppUpdateKind { full, patch }

/// Opening Android's installer is not proof of installation and must not cause
/// this UI to exit. Windows' helper and Android's patch broker own cold UI
/// replacement; neither accepts an arbitrary executable or launch target.
enum FullUpdateHandoff { exitUi, installerOpened }

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdateStatePhase.hidden,
    this.kind,
    this.progress,
    this.availableVersion,
    this.errorCode,
  });
  final AppUpdateStatePhase phase;
  final AppUpdateKind? kind;

  /// Null means that the updater has not supplied a trustworthy byte total.
  final double? progress;
  final String? availableVersion;
  final String? errorCode;
}

class AppUpdatesFailure implements Exception {
  AppUpdatesFailure(String code, {this.retryDownload = false})
    : code = safeAppUpdateCode(code);
  final String code;

  /// A backend can invalidate its prepared cache after a fresh integrity check.
  /// Permission prompts and installer cancellation must not set this hint.
  final bool retryDownload;
  @override
  String toString() => 'AppUpdatesFailure($code)';
}

String safeAppUpdateCode(Object? code) =>
    _safeErrorCodes.contains(code) ? code as String : 'operation_failed';

const _safeErrorCodes = {
  'invalid_request',
  'not_configured',
  'unsupported_platform',
  'updater_unavailable',
  'network_failed',
  'manifest_invalid',
  'signature_invalid',
  'update_incompatible',
  'update_expired',
  'download_failed',
  'integrity_failed',
  'cache_unavailable',
  'update_not_ready',
  'installed_app_required',
  'owner_invalid',
  'permission_denied',
  'install_permission_required',
  'install_cancelled',
  'install_failed',
  'apk_invalid',
  'apk_incompatible',
  'handoff_failed',
  'previous_install_failed',
  'operation_busy',
  'operation_failed',
  'invalid_response',
  'cancelled',
  'timeout',
  'restart_blocked',
  'save_failed',
  'patch_read_failed',
  'patch_check_failed',
  'patch_download_failed',
  'patch_install_failed',
  'patch_no_update',
  'patch_operation_failed',
  'patch_install_unconfirmed',
};

class FullUpdateOffer {
  const FullUpdateOffer({required this.version, this.sizeBytes});
  final String version;
  final int? sizeBytes;
}

class FullUpdateProgress {
  const FullUpdateProgress({required this.received, this.total});
  final int received;
  final int? total;
  double? get fraction =>
      received >= 0 && total != null && total! > 0 && received <= total!
      ? received / total!
      : null;
}

typedef FullUpdateProgressCallback = void Function(FullUpdateProgress progress);

/// A platform-owned download can survive the UI or a temporary loss of network.
/// Its receipt is reconciled without opening an installer or creating a new job.
class FullUpdateResumeState {
  const FullUpdateResumeState({
    required this.offer,
    this.progress,
    this.ready = false,
  });
  final FullUpdateOffer offer;
  final FullUpdateProgress? progress;
  final bool ready;
}

abstract interface class FullUpdatesResumeBackend {
  Future<FullUpdateResumeState?> resume();
}

/// The caller freezes commands, flushes persistence, checks authoritative VPN
/// state, then invokes handoff. Only a platform requiring replacement exits the
/// UI; Android installer handoff releases the reservation. Never disconnects VPN.
typedef BeforeAppRestart = Future<bool> Function(
  AppUpdateKind kind,
  Future<void> Function() handoff,
);

abstract interface class FullUpdatesBackend {
  bool get supported;
  Future<FullUpdateOffer?> check();
  Future<FullUpdateOffer> download(
    FullUpdateOffer offer, {
    required FullUpdateProgressCallback onProgress,
  });
  Future<FullUpdateHandoff> handoff(FullUpdateOffer offer);
  Future<void> restartUi();

  /// Cancels only an owned check/download and completes after it has stopped.
  Future<void> cancel();
  void dispose();
}

class DisabledFullUpdatesBackend implements FullUpdatesBackend {
  const DisabledFullUpdatesBackend();
  @override
  bool get supported => false;
  @override
  Future<FullUpdateOffer?> check() async => null;
  @override
  Future<FullUpdateOffer> download(
    FullUpdateOffer offer, {
    required FullUpdateProgressCallback onProgress,
  }) async => throw AppUpdatesFailure('unsupported_platform');
  @override
  Future<FullUpdateHandoff> handoff(FullUpdateOffer offer) async =>
      throw AppUpdatesFailure('unsupported_platform');
  @override
  Future<void> restartUi() async =>
      throw AppUpdatesFailure('unsupported_platform');
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}
