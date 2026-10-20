// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_updates_types.dart';
import 'dart_updates.dart';
import 'full_updates_platform_stub.dart'
    if (dart.library.io) 'full_updates_platform_native.dart'
    as platform;

export 'app_updates_types.dart';

/// One strip arbitrates complete releases and compatible Dart patches. Complete
/// releases win; a patch remains bound to its own installed base release.
class AppUpdatesController extends ChangeNotifier {
  AppUpdatesController({
    FullUpdatesBackend? fullBackend,
    DartUpdatesController? dartUpdates,
    this.beforeRestart,
    this.autoRestartAfterDownload = true,
    this.resumeCheckInterval = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _full = fullBackend ?? platform.createFullUpdatesBackend(),
       _dart = dartUpdates ?? DartUpdatesController(),
       _ownsDart = dartUpdates == null,
       _now = now ?? DateTime.now {
    _dart.addListener(_onDartChanged);
  }

  final FullUpdatesBackend _full;
  final DartUpdatesController _dart;
  final bool _ownsDart;
  final BeforeAppRestart? beforeRestart;
  final bool autoRestartAfterDownload;
  final Duration resumeCheckInterval;
  final DateTime Function() _now;
  AppUpdateState _state = const AppUpdateState();
  AppUpdateState get state => _state;
  AppUpdateStatePhase get phase => state.phase;
  AppUpdateKind? get kind => state.kind;
  double? get progress => state.progress;
  String? get availableVersion => state.availableVersion;
  String? get errorCode => state.errorCode;
  bool _disposed = false;
  bool _busy = false;
  bool _initialized = false;
  bool _fullReady = false;
  bool _handoffAccepted = false;
  bool _patchAutoRestartPending = false;
  bool _cancelRequested = false;
  FullUpdateOffer? _offer;
  DateTime? _lastCheck;
  Future<void>? _running;
  _Retry _retry = _Retry.check;

  bool get busy => _busy || _dart.busy;
  bool get canCheck => !_disposed && !busy && !_prepared;
  bool get canDownload =>
      !_disposed &&
      !busy &&
      (phase == AppUpdateStatePhase.available ||
          (phase == AppUpdateStatePhase.failed && _retry == _Retry.download));
  bool get canRestart =>
      !_disposed &&
      !busy &&
      _prepared &&
      !_handoffAccepted &&
      phase != AppUpdateStatePhase.restarting;
  bool get _prepared => _fullReady || (_offer == null && _dart.restartRequired);

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    await check(userInitiated: false);
  }

  /// Resume does not poll, replace an offered restart, or overlap another call.
  Future<void> onResume() async {
    if (_disposed || busy) return;
    if (_prepared) return onRestartOpportunity();
    if (!_initialized) return initialize();
    final last = _lastCheck;
    if (last != null && _now().difference(last) < resumeCheckInterval) return;
    await check(userInitiated: false);
  }

  /// A real lifecycle/safety transition may retry a deferred patch once. This
  /// never polls, downloads again, reopens an APK installer, or retries a failed
  /// native handoff. The caller must not generate an edge from our reservation.
  Future<void> onRestartOpportunity() async {
    if (!_patchAutoRestartPending || !canRestart) return;
    await restart();
  }

  Future<void> _preparePatch() async {
    _showPrepared();
    _patchAutoRestartPending =
        autoRestartAfterDownload && beforeRestart != null;
    if (_patchAutoRestartPending) await _restartPrepared();
  }

  Future<void> check({bool userInitiated = true}) => _exclusive(() async {
    if (_prepared &&
        phase == AppUpdateStatePhase.failed &&
        _retry == _Retry.restart) {
      return;
    }
    if (_fullReady) {
      _showPrepared();
      return;
    }
    _lastCheck = _now();
    _retry = _Retry.check;
    _offer = null;
    _set(const AppUpdateState(phase: AppUpdateStatePhase.checking));
    String? fullFailure;
    if (_full.supported) {
      try {
        final offer = await _full.check();
        if (_disposed || _cancelRequested) return;
        if (offer != null) {
          _offer = offer;
          _set(
            AppUpdateState(
              phase: AppUpdateStatePhase.available,
              kind: AppUpdateKind.full,
              availableVersion: offer.version,
            ),
          );
          return;
        }
      } catch (failure) {
        if (_disposed || _cancelRequested) return;
        fullFailure = _code(failure);
        if (fullFailure == 'previous_install_failed') {
          _failed(fullFailure);
          return;
        }
      }
    }
    if (_disposed || _cancelRequested) return;
    await _dart.initialize();
    if (_disposed || _cancelRequested) return;
    if (_dart.restartRequired) {
      await _preparePatch();
      return;
    }
    if (_dart.available) {
      await _dart.check();
      if (_disposed || _cancelRequested) return;
      if (_dart.restartRequired) {
        await _preparePatch();
        return;
      }
      if (_dart.error != null) {
        _failed(_patchCode(_dart.error!), userInitiated: userInitiated);
        return;
      }
      if (_dart.canDownload) {
        _set(
          const AppUpdateState(
            phase: AppUpdateStatePhase.available,
            kind: AppUpdateKind.patch,
          ),
        );
        return;
      }
    } else if (_dart.error != null) {
      _failed(_patchCode(_dart.error!), userInitiated: userInitiated);
      return;
    }
    if (fullFailure != null) {
      _failed(fullFailure, userInitiated: userInitiated);
    } else {
      _set(const AppUpdateState());
    }
  });

  Future<void> download() {
    if (!canDownload) return Future.value();
    return _exclusive(() async {
      final selectedKind = kind;
      _retry = _Retry.download;
      _set(
        AppUpdateState(
          phase: AppUpdateStatePhase.downloading,
          kind: selectedKind,
          availableVersion: _offer?.version,
        ),
      );
      try {
        if (selectedKind == AppUpdateKind.full) {
          final offer = _offer;
          if (offer == null) throw AppUpdatesFailure('update_not_ready');
          var received = 0;
          _offer = await _full.download(
            offer,
            onProgress: (value) {
              if (_disposed || _cancelRequested || value.received < received) {
                return;
              }
              received = value.received;
              _set(
                AppUpdateState(
                  phase: AppUpdateStatePhase.downloading,
                  kind: selectedKind,
                  progress: value.fraction,
                  availableVersion: offer.version,
                ),
              );
            },
          );
          if (_disposed || _cancelRequested) return;
          _fullReady = true;
        } else if (selectedKind == AppUpdateKind.patch) {
          await _dart.download();
          if (_disposed || _cancelRequested) return;
          if (!_dart.restartRequired) {
            throw AppUpdatesFailure(
              _dart.error == null
                  ? 'patch_install_unconfirmed'
                  : _patchCode(_dart.error!),
            );
          }
        } else {
          throw AppUpdatesFailure('update_not_ready');
        }
        _showPrepared();
        _patchAutoRestartPending =
            selectedKind == AppUpdateKind.patch &&
            autoRestartAfterDownload &&
            beforeRestart != null;
        if (autoRestartAfterDownload && beforeRestart != null) {
          await _restartPrepared();
        }
      } catch (failure) {
        if (!_disposed && !_cancelRequested) _failed(_code(failure));
      }
    });
  }

  Future<void> restart() {
    if (!canRestart) return Future.value();
    return _exclusive(_restartPrepared);
  }

  Future<void> _restartPrepared() async {
    if (_disposed || !_prepared || _handoffAccepted) return;
    final selectedKind = _fullReady ? AppUpdateKind.full : AppUpdateKind.patch;
    final callback = beforeRestart;
    _retry = _Retry.restart;
    if (callback == null || _dart.busy) {
      _blocked(selectedKind);
      return;
    }
    _set(
      AppUpdateState(
        phase: AppUpdateStatePhase.restarting,
        kind: selectedKind,
        availableVersion: _offer?.version,
      ),
    );
    var handedOff = false;
    var handoffStarted = false;
    FullUpdateHandoff? outcome;
    try {
      final accepted = await callback(selectedKind, () async {
        if (_disposed || handoffStarted) {
          throw AppUpdatesFailure('restart_blocked');
        }
        handoffStarted = true;
        // Once native work starts, only an explicit retry may replay it.
        _patchAutoRestartPending = false;
        if (selectedKind == AppUpdateKind.full) {
          outcome = await _full.handoff(_offer!);
        } else {
          await _full.restartUi();
          outcome = FullUpdateHandoff.exitUi;
        }
        handedOff = true;
        _handoffAccepted = outcome == FullUpdateHandoff.exitUi;
      });
      if (_disposed) return;
      if (handedOff && outcome == FullUpdateHandoff.installerOpened) {
        // The user can return from source permission/installation or cancel it.
        // Keep the verified package and allow another install attempt; never
        // manufacture an installed state or reserve the UI indefinitely.
        _showPrepared();
      } else if (!accepted || !handedOff) {
        _restartRefused(selectedKind);
      }
    } catch (failure) {
      if (_disposed) return;
      // A lifecycle refusal keeps the prepared package. No disconnect or exit
      // occurs here; the guarded caller owns both persistence and native state.
      if (handedOff && outcome == FullUpdateHandoff.installerOpened) {
        _showPrepared();
      } else if (failure is AppUpdatesFailure && handoffStarted && !handedOff) {
        if (failure.code == 'restart_blocked') {
          _patchAutoRestartPending =
              selectedKind == AppUpdateKind.patch && autoRestartAfterDownload;
          _blocked(selectedKind);
          return;
        }
        if (selectedKind == AppUpdateKind.full &&
            failure.retryDownload &&
            _offer != null) {
          _fullReady = false;
          _retry = _Retry.download;
        }
        _failed(failure.code);
      } else {
        _restartRefused(selectedKind);
      }
    }
  }

  Future<void> retry() => switch (_retry) {
    _Retry.check => check(),
    _Retry.download => download(),
    _Retry.restart => restart(),
  };

  /// Shorebird does not expose cancellation. Retain its busy gate until the SDK
  /// completes; only the separately owned full-package helper can be stopped.
  Future<void> cancel() async {
    if (_disposed || !_busy || kind == AppUpdateKind.patch || _prepared) return;
    if (phase != AppUpdateStatePhase.checking &&
        phase != AppUpdateStatePhase.downloading) {
      return;
    }
    _cancelRequested = true;
    await _full.cancel();
    await _running;
    if (!_disposed) _set(const AppUpdateState());
  }

  Future<void> _exclusive(Future<void> Function() action) {
    if (_disposed || busy) return Future.value();
    _busy = true;
    _cancelRequested = false;
    final running = () async {
      try {
        await action();
      } catch (failure) {
        if (!_disposed && !_cancelRequested) _failed(_code(failure));
      } finally {
        _busy = false;
        if (!_disposed) notifyListeners();
      }
    }();
    _running = running;
    return running;
  }

  void _showPrepared() {
    final selectedKind = _fullReady ? AppUpdateKind.full : AppUpdateKind.patch;
    _retry = _Retry.restart;
    _set(
      AppUpdateState(
        phase: AppUpdateStatePhase.restartReady,
        kind: selectedKind,
        availableVersion: _fullReady
            ? _offer?.version
            : _dart.snapshot?.next?.toString(),
      ),
    );
  }

  void _onDartChanged() {
    if (_disposed) return;
    if (_busy ||
        _offer != null ||
        _fullReady ||
        phase == AppUpdateStatePhase.restarting) {
      notifyListeners();
      return;
    }
    if (_dart.restartRequired) {
      _showPrepared();
    } else if (_dart.busy) {
      _set(
        AppUpdateState(
          phase: _dart.operation == DartUpdateOperation.downloading
              ? AppUpdateStatePhase.downloading
              : AppUpdateStatePhase.checking,
          kind: AppUpdateKind.patch,
        ),
      );
    } else if (_dart.canDownload) {
      _retry = _Retry.download;
      _set(
        const AppUpdateState(
          phase: AppUpdateStatePhase.available,
          kind: AppUpdateKind.patch,
        ),
      );
    } else if (kind == AppUpdateKind.patch) {
      if (_dart.error != null) {
        _failed(_patchCode(_dart.error!));
      } else {
        _set(const AppUpdateState());
      }
    } else {
      notifyListeners();
    }
  }

  void _blocked(AppUpdateKind selectedKind) => _set(
    AppUpdateState(
      phase: AppUpdateStatePhase.blocked,
      kind: selectedKind,
      availableVersion: _offer?.version,
      errorCode: 'restart_blocked',
    ),
  );

  void _restartRefused(AppUpdateKind selectedKind) {
    if (!_handoffAccepted) {
      _blocked(selectedKind);
      return;
    }
    // Accepted native handoff cannot be replayed if closing the window fails.
    _set(
      AppUpdateState(
        phase: AppUpdateStatePhase.restarting,
        kind: selectedKind,
        availableVersion: _offer?.version,
        errorCode: 'handoff_failed',
      ),
    );
  }

  void _failed(String code, {bool userInitiated = true}) => _set(
    AppUpdateState(
      phase: userInitiated || code == 'previous_install_failed'
          ? AppUpdateStatePhase.failed
          : AppUpdateStatePhase.hidden,
      kind: kind,
      availableVersion: _offer?.version,
      errorCode: safeAppUpdateCode(code),
    ),
  );

  void _set(AppUpdateState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dart.removeListener(_onDartChanged);
    _full.dispose();
    if (_ownsDart) _dart.dispose();
    super.dispose();
  }
}

enum _Retry { check, download, restart }

String _code(Object failure) =>
    failure is AppUpdatesFailure ? failure.code : 'operation_failed';

String _patchCode(DartUpdateError error) => switch (error) {
  DartUpdateError.readFailed => 'patch_read_failed',
  DartUpdateError.checkFailed => 'patch_check_failed',
  DartUpdateError.downloadFailed => 'patch_download_failed',
  DartUpdateError.installFailed => 'patch_install_failed',
  DartUpdateError.noUpdate => 'patch_no_update',
  DartUpdateError.operationFailed => 'patch_operation_failed',
};

class AppUpdatesScope extends InheritedNotifier<AppUpdatesController> {
  const AppUpdatesScope({
    super.key,
    required AppUpdatesController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppUpdatesController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdatesScope>()?.notifier;
}
