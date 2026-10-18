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
  bool _connectionChangePending = false;
  bool _disconnectPending = false;
  bool _drainingConnections = false;
  Future<void>? _disconnecting;
  _ConnectionIntent? _queuedConnection;
  _ConnectionIntent? _activeConnection;
  bool _applicationRestartPending = false;
  bool _applicationRestartCommitted = false;
  bool Function()? _applicationRestartSafe;
  String _applicationRestartFailure = 'restart_busy';
  bool get applicationRestartPending => _applicationRestartPending;
  bool get connectionChangePending => _connectionChangePending;
  bool get commandsReserved =>
      _policyPending ||
      _dataUpdatePending ||
      _applicationRestartPending ||
      _disconnectPending;
  bool get canChangeConnection =>
      !_disposed && initialized && !commandsReserved;
  bool get commandPending =>
      _commandPending ||
      _connectionChangePending ||
      _disconnectPending ||
      _policyPending ||
      _dataUpdatePending ||
      _applicationRestartPending;
  String? lastErrorCode;
  String? core;
  ApplicationRoutingPolicy _applicationRouting = ApplicationRoutingPolicy(
    mode: ApplicationRoutingMode.disabled,
  );
  ApplicationRoutingPolicy get applicationRouting => _applicationRouting;
  Set<String> get exclusions =>
      _applicationRouting.mode == ApplicationRoutingMode.exclude
      ? _applicationRouting.applicationIds
      : const {};
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

  /// Pending UI intent is separate from the authoritative native status.
  VpnMode get mode =>
      _queuedConnection?.mode ?? _activeConnection?.mode ?? _mode;
  String? get desiredProfileId =>
      _queuedConnection?.profile.id ??
      _activeConnection?.profile.id ??
      status.activeProfileId;
  bool get modeSwitchSupported =>
      bridge is ConnectionModeBridge &&
      (bridge as ConnectionModeBridge).supportsConnectionModes &&
      status.systemProxySupported;
  bool get _serverReconnectSupported =>
      modeSwitchSupported ||
      (bridge is ServerReconnectBridge &&
          (bridge as ServerReconnectBridge).supportsServerReconnect);

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
    await requestConnection(profile);
  }

  /// Coalesces UI changes while one native command is awaiting acknowledgement.
  /// Superseding uses native reconnect, never an unprotected disconnect/connect.
  Future<bool> requestConnection(ConnectionProfile profile, {VpnMode? mode}) {
    if (!canChangeConnection) return Future.value(false);
    final requestedMode = mode ?? this.mode;
    if (status.cleanupRequired ||
        ((status.phase == VpnPhase.error || status.phase == VpnPhase.blocked) &&
            !_connectionChangePending)) {
      return Future.value(_reject('mode_switch_requires_connected'));
    }
    final reconnect = _drainingConnections || canDisconnect;
    if ((reconnect && !_serverReconnectSupported) ||
        (requestedMode != VpnMode.vpn && !modeSwitchSupported)) {
      return Future.value(_reject('mode_unsupported'));
    }
    final desired = _queuedConnection ?? _activeConnection;
    if (desired != null &&
        !desired.result.isCompleted &&
        desired.profile.id == profile.id &&
        desired.mode == requestedMode) {
      return desired.result.future;
    }
    if (!_connectionChangePending &&
        status.activeProfileId == profile.id &&
        status.mode == requestedMode &&
        (status.phase == VpnPhase.connected || connecting)) {
      return Future.value(true);
    }
    _queuedConnection?.complete(false);
    _activeConnection?.complete(false);
    final intent = _ConnectionIntent(profile, requestedMode, reconnect);
    _queuedConnection = intent;
    _connectionChangePending = true;
    _mayHaveTunnel = true;
    if (!reconnect) _mode = requestedMode;
    if (!_drainingConnections) {
      _drainingConnections = true;
      unawaited(_drainConnections());
    }
    _changed();
    return intent.result.future;
  }

  Future<void> _drainConnections() async {
    try {
      while (!_disposed && _queuedConnection != null) {
        final intent = _queuedConnection!;
        _queuedConnection = null;
        _activeConnection = intent;
        final accepted = await _run(() {
          if (intent.reconnect) {
            if (!modeSwitchSupported && intent.mode == VpnMode.vpn) {
              return (bridge as ServerReconnectBridge).reconnectServer(
                intent.profile,
              );
            }
            return (bridge as ConnectionModeBridge).reconnect(
              intent.profile,
              intent.mode,
            );
          }
          return modeSwitchSupported
              ? (bridge as ConnectionModeBridge).connectInMode(
                  intent.profile,
                  intent.mode,
                )
              : bridge.connect(intent.profile);
        });
        intent.complete(accepted && !_disconnectPending && !_disposed);
        _activeConnection = null;
      }
    } finally {
      _activeConnection?.complete(false);
      _activeConnection = null;
      _drainingConnections = false;
      _connectionChangePending = false;
      _changed();
    }
  }

  Future<bool> switchServer(ConnectionProfile profile) async {
    if (!canChangeConnection) return false;
    if (!canDisconnect && !_connectionChangePending) {
      return _reject('mode_switch_requires_connected');
    }
    return requestConnection(profile);
  }

  Future<bool> changeMode(
    VpnMode requested, {
    ConnectionProfile? profile,
  }) async {
    if (!canChangeConnection) return false;
    if (!modeSwitchSupported) return _reject('mode_unsupported');
    if (status.phase == VpnPhase.disconnected &&
        !canDisconnect &&
        !_connectionChangePending) {
      if (_mode != requested) {
        _mode = requested;
        lastErrorCode = null;
        _changed();
      }
      return true;
    }
    if (status.phase != VpnPhase.connected &&
        !connecting &&
        !_connectionChangePending) {
      return _reject('mode_switch_requires_connected');
    }
    if (mode == requested) return true;
    if (profile == null) return _reject('profile_required');
    if (!_connectionChangePending &&
        !connecting &&
        profile.id != status.activeProfileId) {
      return _reject('mode_profile_mismatch');
    }
    return requestConnection(profile, mode: requested);
  }

  bool _reject(String code) {
    lastErrorCode = code;
    _changed();
    return false;
  }

  Future<void> disconnect() {
    if (_disposed || commandsReserved && !_disconnectPending) {
      return Future.value();
    }
    if (_disconnecting != null) return _disconnecting!;
    _queuedConnection?.complete(false);
    _queuedConnection = null;
    _activeConnection?.complete(false);
    _activeConnection = null;
    _disconnectPending = true;
    final pending = () async {
      try {
        await _run(bridge.disconnect);
      } finally {
        _disconnectPending = false;
        _disconnecting = null;
        _changed();
      }
    }();
    _disconnecting = pending;
    return pending;
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

  Future<void> setExclusions(Set<String> ids) => setApplicationRouting(
    ApplicationRoutingPolicy(
      mode: ids.isEmpty
          ? ApplicationRoutingMode.disabled
          : ApplicationRoutingMode.exclude,
      applicationIds: ids,
    ),
  );

  Future<void> setApplicationRouting(ApplicationRoutingPolicy policy) async {
    if (canDisconnect || commandPending) {
      throw const VpnFailure('reconnect_required');
    }
    final requested = ApplicationRoutingPolicy(
      mode: policy.mode,
      applicationIds: policy.applicationIds,
    );
    final revision = ++_policyRevision;
    _policyPending = true;
    _changed();
    try {
      if (bridge is ApplicationRoutingBridge) {
        await (bridge as ApplicationRoutingBridge).setApplicationRouting(
          requested,
        );
      } else {
        if (requested.mode == ApplicationRoutingMode.include) {
          throw const VpnFailure('application_routing_unsupported');
        }
        await bridge.setExclusions(
          requested.mode == ApplicationRoutingMode.exclude
              ? requested.applicationIds
              : const {},
        );
      }
      if (!_disposed && revision == _policyRevision) {
        _applicationRouting = requested;
      }
    } finally {
      _policyPending = false;
      _changed();
    }
  }

  Future<void> loadExclusions() => loadApplicationRouting();

  Future<void> loadApplicationRouting() async {
    if (_policyPending) throw const VpnFailure('operation_in_progress');
    final revision = ++_policyRevision;
    final ApplicationRoutingPolicy value;
    if (bridge is ApplicationRoutingBridge) {
      value = await (bridge as ApplicationRoutingBridge)
          .getApplicationRouting()
          .timeout(const Duration(seconds: 10));
    } else {
      final ids = await bridge.getExclusions().timeout(
        const Duration(seconds: 10),
      );
      value = ApplicationRoutingPolicy(
        mode: ids.isEmpty
            ? ApplicationRoutingMode.disabled
            : ApplicationRoutingMode.exclude,
        applicationIds: ids,
      );
    }
    if (!_disposed && revision == _policyRevision) {
      _applicationRouting = value;
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
    _queuedConnection?.complete(false);
    _queuedConnection = null;
    _activeConnection?.complete(false);
    _activeConnection = null;
    _states?.cancel();
    _traffic?.cancel();
    super.dispose();
  }
}

final class _ConnectionIntent {
  _ConnectionIntent(this.profile, this.mode, this.reconnect);
  final ConnectionProfile profile;
  final VpnMode mode;
  final bool reconnect;
  final Completer<bool> result = Completer<bool>();
  void complete(bool accepted) {
    if (!result.isCompleted) result.complete(accepted);
  }
}

String vpnErrorText(String? code) => switch (code) {
  'native_storage_unavailable' => 'Не удалось прочитать или сохранить защищённые настройки VPN. Соединение не восстановлено автоматически.',
  'exclusions_unavailable' => 'Не удалось прочитать сохранённые исключения. Перезапустите службу или явно сбросьте список в настройках исключений.',
  'system_testing_required' => 'Эта сборка требует проверки VPN в Windows. Системное подключение ещё не разрешено установщиком.',
  'permission_denied' => 'Разрешение VPN не предоставлено. Попробуйте ещё раз.',
  'vpn_permission_unavailable' =>
    'Не удалось открыть запрос VPN. Откройте приложение и попробуйте ещё раз.',
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
  'application_routing_unsupported' => 'Этот режим маршрутизации приложений недоступен. Обновите установленную ExVPN.',
  'application_routing_rejected' => 'Не удалось применить маршрутизацию приложений. Проверьте выбранные приложения.',
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
