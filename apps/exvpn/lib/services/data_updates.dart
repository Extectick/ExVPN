// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'data_updates_platform_stub.dart'
    if (dart.library.io) 'data_updates_platform_native.dart'
    as platform;
import 'data_updates_types.dart';
import 'native_vpn_bridge.dart';
import 'vpn_controller.dart';
export 'data_updates_types.dart';

final class DataUpdatesController extends ChangeNotifier {
  DataUpdatesController({required this.vpn, DataUpdatesBackend? backend})
    : _backend = backend ?? platform.createDataUpdatesBackend() {
    vpn?.addListener(_changed);
  }
  final VpnController? vpn;
  final DataUpdatesBackend _backend;
  DataUpdateSnapshot snapshot = const DataUpdateSnapshot();
  DataUpdateProposal? proposal;
  bool busy = false;
  bool initialized = false;
  bool _disposed = false;
  bool _started = false;
  String? errorCode;
  String? notice;
  bool get enabled => _backend.enabled;
  String? get disabledReason => _backend.disabledReason;
  String get channel => _backend.channel;
  bool get canApply =>
      proposal != null && !busy && vpn?.canApplyDataUpdate == true;

  Future<void> initialize() async {
    if (_started) return;
    _started = true;
    await recover();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_disposed || busy) return;
    busy = true;
    errorCode = null;
    notice = null;
    _changed();
    try {
      await action();
    } on DataUpdatesFailure catch (error) {
      errorCode = error.code;
    } on VpnFailure {
      errorCode = 'update_requires_disconnected';
    } catch (_) {
      errorCode = 'operation_failed';
    } finally {
      busy = false;
      _changed();
      if (_disposed) {
        try {
          await _backend.cancel();
        } catch (_) {}
      }
    }
  }

  Future<void> recover() => _run(() async {
    if (proposal != null) throw const DataUpdatesFailure('busy');
    await _readSaved();
  });

  Future<void> _readSaved({String? successNotice}) async {
    final restored = await _backend.recover();
    if (_disposed) return;
    snapshot = restored;
    initialized = true;
    notice = restored.recoveredPrevious
        ? 'Восстановлена предыдущая проверенная ревизия.'
        : successNotice;
  }

  Future<void> check() => _run(() async {
    if (!enabled) throw const DataUpdatesFailure('disabled');
    if (proposal != null) throw const DataUpdatesFailure('busy');
    try {
      final candidate = await _backend.stage();
      if (_disposed) {
        await _backend.cancel();
        return;
      }
      proposal = candidate;
    } on DataUpdatesFailure catch (error) {
      if (error.code == 'staleRevision') {
        // Another process may have committed a new revision since this UI
        // started. A replay response must not leave the displayed snapshot stale.
        await _readSaved(successNotice: 'Новой подписанной ревизии нет.');
      } else {
        rethrow;
      }
    }
  });

  Future<void> apply() => _run(() async {
    final controller = vpn;
    if (proposal == null) throw const DataUpdatesFailure('stageUnavailable');
    if (controller == null || !controller.canApplyDataUpdate) {
      throw const DataUpdatesFailure('update_requires_disconnected');
    }
    var consumed = false;
    try {
      final active = await controller.runWhileDisconnected((stillSafe) async {
        consumed = true;
        return _backend.apply(() => !_disposed && stillSafe());
      });
      if (!_disposed) {
        snapshot = active;
        initialized = true;
        notice = 'Данные обновлены. VPN не перезапускался.';
      }
    } catch (_) {
      if (consumed && !_disposed) {
        // Publication may have succeeded before a post-commit read failed.
        // Reconcile independently; a second read failure preserves working text.
        try {
          await _readSaved(
            successNotice: 'Сохранённые данные повторно проверены.',
          );
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (consumed) proposal = null;
    }
  });

  Future<void> cancel() => _run(() async {
    await _backend.cancel();
    proposal = null;
    notice = 'Подготовленное обновление отменено.';
  });

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    vpn?.removeListener(_changed);
    if (!busy) unawaited(_backend.cancel().catchError((Object _) {}));
    super.dispose();
  }
}

class DataUpdatesScope extends InheritedNotifier<DataUpdatesController> {
  const DataUpdatesScope({
    super.key,
    required DataUpdatesController controller,
    required super.child,
  }) : super(notifier: controller);
  static DataUpdatesController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DataUpdatesScope>()?.notifier;
}

String dataUpdatesErrorText(String? code) => switch (code) {
  'update_requires_disconnected' || 'activationDeferred' => 'Применение отложено: требуется подтверждённо отключённый VPN без выполняющихся команд. Повторите проверку состояния.',
  'invalidSignature' || 'untrustedKey' || 'hashMismatch' =>
    'Подлинность обновления не подтверждена. Данные не применены.',
  'incompatible' =>
    'Обновление предназначено для другой версии приложения или канала.',
  'downloadFailed' || 'timeout' =>
    'Не удалось загрузить обновление. Проверьте сеть и повторите попытку.',
  'storageFailure' || 'corruptState' => 'Не удалось прочитать или записать данные обновления. Используется доступный рабочий набор.',
  'invalidManifest' ||
  'invalidEnvelope' ||
  'invalid_resource' ||
  'pathDenied' ||
  'tooLarge' => 'Пакет обновления не прошёл проверку формата и ограничений.',
  'busy' => 'Другая операция обновления ещё не завершена.',
  'disabled' => 'Доставка данных в этой сборке не настроена.',
  _ => 'Операция обновления не выполнена. Повторите попытку.',
};
