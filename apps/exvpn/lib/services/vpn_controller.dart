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
  bool _applicationRestartPending = false;
  bool _applicationRestartCommitted = false;
  bool Function()? _applicationRestartSafe;
  String _applicationRestartFailure = 'restart_busy';
  bool get applicationRestartPending => _applicationRestartPending;
  bool get commandPending =>
      _commandPending ||
      _policyPending ||
      _dataUpdatePending ||
      _applicationRestartPending;
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
  VpnMode _mode = VpnMode.vpn;

  /// The desired mode is retained while idle; active native state wins.
  VpnMode get mode => _mode;
  bool get modeSwitchSupported =>
      bridge is ConnectionModeBridge &&
      (bridge as ConnectionModeBridge).supportsConnectionModes &&
      status.systemProxySupported;

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

  /// Reserves VPN commands while storage is flushed and a native updater takes
  /// ownership of a UI restart. A Dart-only restart leaves the service and its
  /// proxy lease untouched. An installer additionally requires native idle state.
  Future<T> runForApplicationRestart<T>(
    Future<T> Function(bool Function() stillSafe) action, {
    bool requireDisconnected = false,
  }) async {
    final failure = requireDisconnected
        ? 'update_requires_disconnected'
        : 'restart_busy';
    if (_disposed ||
        !initialized ||
        commandPending ||
        (requireDisconnected && !canApplyDataUpdate)) {
      throw VpnFailure(failure);
    }
    _applicationRestartPending = true;
    _applicationRestartCommitted = false;
    _applicationRestartFailure = failure;
    _changed();
    try {
      await refresh();
      final epoch = _unsafeEpoch;
      final command = _command;
      bool stillSafe() =>
          !_disposed &&
          initialized &&
          _applicationRestartPending &&
          !_commandPending &&
          !_policyPending &&
          !_dataUpdatePending &&
          command == _command &&
          (!requireDisconnected ||
              (!canDisconnect &&
                  status.phase == VpnPhase.disconnected &&
                  epoch == _unsafeEpoch));
      _applicationRestartSafe = stillSafe;
      if (!stillSafe()) throw VpnFailure(failure);
      return await action(stillSafe);
    } finally {
      _applicationRestartSafe = null;
      if (!_applicationRestartCommitted) _applicationRestartPending = false;
      _changed();
    }
  }

  /// Once the native handoff is accepted, retain the reservation until UI
  /// destruction. A posted native exit may outlive its channel acknowledgement.
  void commitApplicationRestart() {
    final stillSafe = _applicationRestartSafe;
    if (stillSafe == null || !stillSafe()) {
      throw VpnFailure(_applicationRestartFailure);
    }
    _applicationRestartCommitted = true;
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
        value.mode != status.mode ||
        value.connectedAt != status.connectedAt) {
      _clearStatistics();
    }
    status = value;
    if (value.phase != VpnPhase.disconnected || value.cleanupRequired) {
      _mode = value.mode;
    }
    _mayHaveTunnel =
        value.cleanupRequired ||
        switch (value.phase) {
          VpnPhase.disconnected => false,
          VpnPhase.error => _mayHaveTunnel || value.activeProfileId != null,
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
      mode: status.mode,
      systemProxySupported: status.systemProxySupported,
      cleanupRequired: status.cleanupRequired,
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
    if (_disposed ||
        !initialized ||
        commandPending ||
        canDisconnect ||
        status.phase != VpnPhase.disconnected) {
      return;
    }
    if (_mode != VpnMode.vpn && !modeSwitchSupported) {
      _reject('mode_unsupported');
      return;
    }
    final modeBridge = modeSwitchSupported
        ? bridge as ConnectionModeBridge
        : null;
    _mayHaveTunnel = true;
    await _run(
      () => modeBridge == null
          ? bridge.connect(profile)
          : modeBridge.connectInMode(profile, _mode),
    );
  }

  /// A native reconfiguration keeps the protection guard owned throughout.
  /// Never emulate this with disconnect followed by connect in the UI process.
  Future<bool> switchServer(ConnectionProfile profile) async {
    if (_disposed || !initialized || commandPending || connecting) return false;
    if (status.phase != VpnPhase.connected) {
      return _reject('mode_switch_requires_connected');
    }
    if (profile.id == status.activeProfileId) return true;
    if (!modeSwitchSupported) return _reject('mode_unsupported');
    return _run(
      () => (bridge as ConnectionModeBridge).reconnect(profile, status.mode),
    );
  }

  Future<bool> changeMode(
    VpnMode requested, {
    ConnectionProfile? profile,
  }) async {
    if (_disposed || !initialized || commandPending || connecting) return false;
    if (!modeSwitchSupported) return _reject('mode_unsupported');
    if (status.phase == VpnPhase.disconnected && !canDisconnect) {
      if (_mode != requested) {
        _mode = requested;
        lastErrorCode = null;
        _changed();
      }
      return true;
    }
    if (status.phase != VpnPhase.connected) {
      return _reject('mode_switch_requires_connected');
    }
    if (status.mode == requested) return true;
    if (profile == null) return _reject('profile_required');
    if (profile.id != status.activeProfileId) {
      return _reject('mode_profile_mismatch');
    }
    return _run(
      () => (bridge as ConnectionModeBridge).reconnect(profile, requested),
    );
  }

  bool _reject(String code) {
    lastErrorCode = code;
    _changed();
    return false;
  }

  Future<void> disconnect() async {
    if (_applicationRestartPending) return;
    await _run(bridge.disconnect);
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_disposed) return false;
    final command = ++_command;
    _commandPending = true;
    lastErrorCode = null;
    var accepted = false;
    _changed();
    try {
      await action();
      accepted = true;
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
    return accepted &&
        !_disposed &&
        command == _command &&
        lastErrorCode == null &&
        status.phase != VpnPhase.error &&
        status.phase != VpnPhase.blocked;
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
  'exclusions_unavailable' => 'Не удалось прочитать сохранённые исключения. Перезапустите службу или явно сбросьте список в настройках исключений.',
  'system_testing_required' => 'Эта сборка требует проверки VPN в Windows. Системное подключение ещё не разрешено установщиком.',
  'permission_denied' => 'Разрешите VPN в системном запросе.',
  'permission_cancelled' => 'Запрос подключения отменён.',
  'native_core_unavailable' ||
  'native_unavailable' => 'VPN-модуль недоступен в этой сборке.',
  'service_not_installed' || 'service_unavailable' || 'ipc_unavailable' =>
    'Служба ExVPN недоступна. Проверьте установку приложения.',
  'service_access_denied' => 'Нет доступа к службе ExVPN.',
  'mode_unsupported' =>
    'Смена режима недоступна. Обновите установленную ExVPN.',
  'mode_invalid' ||
  'connection_mode_rejected' => 'Этот режим подключения не поддерживается.',
  'connection_busy' => 'Подключение уже изменяется. Дождитесь завершения.',
  'mode_switch_requires_connected' => 'Состояние подключения изменилось. Отключите соединение и попробуйте снова.',
  'mode_profile_mismatch' =>
    'Активный сервер изменился. Повторите выбор режима.',
  'proxy_query_failed' ||
  'proxy_store_unavailable' => 'Не удалось прочитать настройки прокси Windows.',
  'proxy_setup_failed' ||
  'proxy_invalid_endpoint' ||
  'proxy_unavailable' ||
  'proxy_start_failed' ||
  'proxy_endpoint_unavailable' ||
  'proxy_bind_failed' => 'Не удалось включить системный прокси Windows.',
  'proxy_stop_failed' => 'Не удалось остановить прокси. Повторите отключение.',
  'proxy_unreachable' => 'Прокси-сервер недоступен. Выберите другой сервер.',
  'proxy_exclusions_unsupported' =>
    'Исключения приложений доступны только в режиме VPN.',
  'proxy_requires_guard_recovery' =>
    'Сначала отключите VPN, чтобы снять блокировку сети.',
  'proxy_restore_failed' => 'Не удалось восстановить настройки прокси Windows.',
  'proxy_settings_changed' || 'proxy_settings_conflict' =>
    'Настройки прокси Windows изменены другим приложением.',
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
