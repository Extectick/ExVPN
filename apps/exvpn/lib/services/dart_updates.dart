// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'dart_updates_platform_stub.dart'
    if (dart.library.io) 'dart_updates_platform_native.dart'
    as platform;
import 'dart_updates_types.dart';
export 'dart_updates_types.dart';

enum DartUpdateOperation { idle, reading, checking, downloading }

class DartUpdatesController extends ChangeNotifier {
  DartUpdatesController({DartUpdatesBackend? backend})
    : _backend =
          backend ??
          platform.createDartUpdatesBackend(
            const String.fromEnvironment(
              'EXVPN_DART_UPDATE_TRACK',
              defaultValue: 'stable',
            ),
          );
  final DartUpdatesBackend _backend;
  DartPatchSnapshot? snapshot;
  DartUpdateStatus? status;
  DartUpdateError? error;
  DartUpdateOperation operation = DartUpdateOperation.idle;
  bool slow = false;
  bool downloadUnconfirmed = false;
  bool _disposed = false;
  Timer? _slowTimer;

  String get track => _backend.track;
  String? get disabledReason => _backend.disabledReason;
  bool get busy => operation != DartUpdateOperation.idle;
  bool get available => snapshot?.available == true;
  bool get restartRequired =>
      snapshot?.restartRequired == true ||
      status == DartUpdateStatus.restartRequired;
  bool get canCheck => !_disposed && available && !busy;
  bool get canDownload =>
      canCheck && !restartRequired && status == DartUpdateStatus.outdated;

  Future<void> initialize() async {
    if (snapshot != null) return;
    await refresh();
  }

  Future<void> refresh() => _run(DartUpdateOperation.reading, () async {
    _acceptRead(await _backend.read());
  });

  Future<void> check() async {
    if (!canCheck) return;
    await _run(DartUpdateOperation.checking, () async {
      final result = await _backend.check();
      if (_disposed) return;
      snapshot = result.snapshot;
      status = result.snapshot.available
          ? result.status
          : DartUpdateStatus.unavailable;
    });
  }

  Future<void> download() async {
    if (!canDownload) return;
    await _run(DartUpdateOperation.downloading, () async {
      _acceptRead(await _backend.download());
      if (!_disposed && available && !restartRequired) {
        downloadUnconfirmed = true;
      }
    });
  }

  void _acceptRead(DartPatchSnapshot value) {
    if (_disposed) return;
    snapshot = value;
    status = !value.available
        ? DartUpdateStatus.unavailable
        : value.restartRequired
        ? DartUpdateStatus.restartRequired
        : null;
  }

  Future<void> _run(
    DartUpdateOperation nextOperation,
    Future<void> Function() action,
  ) async {
    if (_disposed || busy) return;
    operation = nextOperation;
    error = null;
    slow = false;
    downloadUnconfirmed = false;
    notifyListeners();
    if (_disposed) return;
    _slowTimer = Timer(const Duration(seconds: 30), () {
      if (!_disposed) {
        slow = true;
        notifyListeners();
      }
    });
    try {
      await action();
    } catch (failure) {
      if (_disposed) return;
      error = failure is DartUpdatesFailure
          ? failure.code
          : DartUpdateError.operationFailed;
      // A failed check may already have scheduled rollback. Invalidate stale
      // metadata and reconcile locally; never start a second network operation.
      snapshot = null;
      status = null;
      if (nextOperation != DartUpdateOperation.reading) {
        try {
          _acceptRead(await _backend.read());
        } catch (_) {}
      }
    } finally {
      _slowTimer?.cancel();
      if (!_disposed) {
        operation = DartUpdateOperation.idle;
        slow = false;
        notifyListeners();
      }
    }
    // There is no cancellable SDK operation. A slow call retains the busy gate
    // until it actually ends; a Dart timeout must not allow concurrent downloads.
  }

  @override
  void dispose() {
    _disposed = true;
    _slowTimer?.cancel();
    super.dispose();
  }
}

class DartUpdatesScope extends InheritedNotifier<DartUpdatesController> {
  const DartUpdatesScope({
    super.key,
    required DartUpdatesController controller,
    required super.child,
  }) : super(notifier: controller);
  static DartUpdatesController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DartUpdatesScope>()?.notifier;
}

String dartUpdatesErrorText(DartUpdateError error) => switch (error) {
  DartUpdateError.readFailed => 'Не удалось определить текущий и подготовленный Dart-патч. Повторите чтение версии.',
  DartUpdateError.checkFailed =>
    'Не удалось проверить Dart-обновления. Проверьте сеть и повторите попытку.',
  DartUpdateError.downloadFailed =>
    'Dart-патч не загружен. Проверьте сеть и повторите проверку.',
  DartUpdateError.installFailed =>
    'Движок отклонил Dart-патч. Его установка не подтверждена.',
  DartUpdateError.noUpdate => 'Доступный патч изменился. Повторите проверку.',
  DartUpdateError.operationFailed =>
    'Операция Dart-обновления не выполнена. Повторите проверку состояния.',
};
