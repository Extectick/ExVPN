import 'dart:async';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';

import 'native_vpn_bridge.dart';

/// Native status is authoritative. Command acknowledgement never means connected.
final class VpnController extends ChangeNotifier {
  VpnController(this.bridge);
  final VpnBridge bridge;
  VpnStatus status = const VpnStatus(
    phase: VpnPhase.disconnected,
    processCrashProtection: false,
  );
  TrafficStats stats = const TrafficStats(uploadBytes: 0, downloadBytes: 0);
  bool statisticsAvailable = false;
  bool initialized = false;
  bool _commandPending = false;
  bool _policyPending = false;
  bool _dataUpdatePending = false;
  bool get commandPending =>
      _commandPending || _policyPending || _dataUpdatePending;
  String? lastErrorCode;
  String? core;
  Set<String> exclusions = {};
  StreamSubscription<VpnStatus>? _states;
  StreamSubscription<TrafficStats>? _traffic;
  bool _disposed = false;
  int _revision = 0;
  int _command = 0;
  int _policyRevision = 0;
  bool _started = false;
  bool _mayHaveTunnel = false;
  int _unsafeEpoch = 0;

  bool get canApplyDataUpdate =>
      !_disposed &&
      initialized &&
      !commandPending &&
      status.phase == VpnPhase.disconnected &&
      !canDisconnect;

  /// Reserves UI connect/policy commands and refreshes the authoritative native
  /// state. OS-initiated VPN starts remain independent; the predicate detects
  /// reported state changes before a data commit, never restarts/stops the core.
  Future<T> runWhileDisconnected<T>(
    Future<T> Function(bool Function() stillSafe) action,
  ) async {
    if (!canApplyDataUpdate) {
      throw const VpnFailure('update_requires_disconnected');
    }
    _dataUpdatePending = true;
    _changed();
    try {
      await refresh();
      final epoch = _unsafeEpoch;
      final command = _command;
      bool stillSafe() =>
          !_disposed &&
          initialized &&
          _dataUpdatePending &&
          !_commandPending &&
          !_policyPending &&
          !canDisconnect &&
          status.phase == VpnPhase.disconnected &&
          epoch == _unsafeEpoch &&
          command == _command;
      if (!stillSafe()) throw const VpnFailure('update_requires_disconnected');
      return await action(stillSafe);
    } finally {
      _dataUpdatePending = false;
      _changed();
    }
  }

  bool get canDisconnect =>
      _mayHaveTunnel ||
      switch (status.phase) {
        VpnPhase.requestingPermission ||
        VpnPhase.connecting ||
        VpnPhase.connected ||
        VpnPhase.reconnecting ||
        VpnPhase.blocked => true,
        _ => false,
      };
  bool get connecting =>
      status.phase == VpnPhase.connecting ||
      status.phase == VpnPhase.reconnecting ||
      status.phase == VpnPhase.requestingPermission;

  Future<void> initialize() async {
    if (_started) return;
    _started = true;
    _states = bridge.statuses.listen(
      _accept,
      onError: (Object error) => _lost(error),
      onDone: () => _lost(const VpnFailure('channel_closed')),
    );
    _traffic = bridge.traffic.listen(
      (value) {
        if (!_disposed && status.phase == VpnPhase.connected) {
          stats = value;
          statisticsAvailable = true;
          _changed();
        }
      },
      onError: (Object _) {
        _clearStatistics();
        _changed();
      },
      onDone: () {
        _clearStatistics();
        _changed();
      },
    );
    await refresh();
    try {
      final value = await bridge.coreVersion();
      if (!_disposed) {
        core = value;
        _changed();
      }
    } catch (_) {
      /* Report only connection failures in the main state. */
    }
  }

  void _accept(VpnStatus value) {
    if (_disposed) return;
    _revision++;
    if (value.phase != VpnPhase.disconnected) _unsafeEpoch++;
    initialized = true;
    if (value.phase != VpnPhase.connected ||
        status.phase != VpnPhase.connected ||
        value.activeProfileId != status.activeProfileId ||
        value.connectedAt != status.connectedAt) {
      _clearStatistics();
    }
    status = value;
    _mayHaveTunnel = switch (value.phase) {
      VpnPhase.disconnected => false,
      VpnPhase.error => _mayHaveTunnel,
      _ => true,
    };
    lastErrorCode = value.errorCode;
    _changed();
  }

  void _clearStatistics() {
    stats = const TrafficStats(uploadBytes: 0, downloadBytes: 0);
    statisticsAvailable = false;
  }

  void _lost(Object error) {
    if (_disposed) return;
    _revision++;
    _unsafeEpoch++;
    initialized = true;
    _clearStatistics();
    lastErrorCode = error is VpnFailure ? error.code : 'ipc_disconnected';
    status = VpnStatus(
      phase: VpnPhase.error,
      processCrashProtection: false,
      activeProfileId: status.activeProfileId,
      errorCode: lastErrorCode,
    );
    _changed();
  }

  Future<void> refresh() async {
    final before = _revision;
    try {
      final value = await bridge.getStatus().timeout(
        const Duration(seconds: 10),
      );
      if (!_disposed && before == _revision) _accept(value);
    } catch (error) {
      if (!_disposed && before == _revision) _lost(error);
    }
    if (!_disposed && !_policyPending) {
      try {
        await loadExclusions();
      } catch (_) {
        // Settings reports a failed policy read. It must not replace VPN status.
      }
    }
  }

  Future<void> connect(ConnectionProfile profile) async {
    if (!initialized || commandPending || canDisconnect) return;
    _mayHaveTunnel = true;
    await _run(() => bridge.connect(profile));
  }

  Future<void> disconnect() => _run(bridge.disconnect);
  Future<void> _run(Future<void> Function() action) async {
    final command = ++_command;
    _commandPending = true;
    lastErrorCode = null;
    _changed();
    try {
      await action();
    } catch (error) {
      if (!_disposed && command == _command) {
        lastErrorCode = error is VpnFailure ? error.code : 'native_failure';
      }
    } finally {
      if (!_disposed && command == _command) {
        final commandError = lastErrorCode;
        await refresh();
        if (!_disposed && command == _command) {
          _commandPending = false;
          if (commandError != null) lastErrorCode = commandError;
        }
        _changed();
      }
    }
  }

  Future<void> setExclusions(Set<String> ids) async {
    if (canDisconnect || commandPending) {
      throw const VpnFailure('reconnect_required');
    }
    final requested = Set<String>.unmodifiable(ids);
    final revision = ++_policyRevision;
    _policyPending = true;
    _changed();
    try {
      await bridge.setExclusions(requested);
      if (!_disposed && revision == _policyRevision) {
        exclusions = requested;
      }
    } finally {
      _policyPending = false;
      _changed();
    }
  }

  Future<void> loadExclusions() async {
    if (_policyPending) throw const VpnFailure('operation_in_progress');
    final revision = ++_policyRevision;
    final value = await bridge.getExclusions().timeout(
      const Duration(seconds: 10),
    );
    if (!_disposed && revision == _policyRevision) {
      exclusions = Set.unmodifiable(value);
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _command++;
    _states?.cancel();
    _traffic?.cancel();
    super.dispose();
  }
}

String vpnErrorText(String? code) => switch (code) {
  'native_storage_unavailable' => 'Не удалось прочитать или сохранить защищённые настройки VPN. Соединение не восстановлено автоматически.',
  'exclusions_unavailable' => 'Не удалось подтвердить сохранённые исключения. Перезапустите службу и повторите чтение настроек.',
  'system_testing_required' => 'Эта сборка требует проверки VPN в Windows. Системное подключение ещё не разрешено установщиком.',
  'permission_denied' => 'Разрешите VPN в системном запросе.',
  'permission_cancelled' => 'Запрос подключения отменён.',
  'native_core_unavailable' ||
  'native_unavailable' => 'VPN-модуль недоступен в этой сборке.',
  'service_not_installed' || 'service_unavailable' || 'ipc_unavailable' =>
    'Служба ExVPN недоступна. Проверьте установку приложения.',
  'service_access_denied' => 'Нет доступа к службе ExVPN.',
  'network_unavailable' =>
    'Нет доступной сети. Проверьте подключение к интернету.',
  'reconnect_required' => 'Сначала отключите VPN, затем измените исключения.',
  'transport_unreachable' =>
    'Связь с VPN-сервером потеряна. Проверяем его доступность.',
  'guard_recovered' => 'Служба VPN перезапущена. Доступ к сети остаётся заблокирован. Отключите VPN, затем подключитесь снова.',
  'invalid_profile' ||
  'profile_rejected' ||
  'core_config_rejected' ||
  'config_invalid' ||
  'invalid_config' => 'Параметры этого сервера не поддерживаются.',
  'profile_required' => 'Выберите сервер для восстановления соединения.',
  'vpn_permission_revoked' => 'Разрешение VPN отозвано в системе.',
  'tunnel_https_failed' ||
  'tunnel_health_failed' ||
  'tunnel_https_status' ||
  'tunnel_unreachable' => 'Сервер не прошёл проверку HTTPS. Попробуйте подключиться к другому серверу.',
  'endpoint_resolution_failed' => 'Не удалось определить адрес VPN-сервера.',
  'invalid_exclusion' ||
  'shared_uid_requires_all_packages' ||
  'exclusions_rejected' => 'Не удалось применить исключения приложений.',
  'probe_requires_active_tunnel' =>
    'Проверка доступна после подключения к этому серверу.',
  'ipc_disconnected' || 'channel_closed' || 'invalid_native_response' =>
    'Не удалось подтвердить состояние VPN. Защита не подтверждена.',
  _ => 'Не удалось подключиться. Проверьте сеть и выберите другой сервер.',
};
