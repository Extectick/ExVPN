import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vpn_permission_setup.dart';

/// Only stable diagnostic codes cross into UI. Platform messages can contain
/// private endpoint/configuration data and are deliberately discarded.
final class VpnFailure implements Exception {
  const VpnFailure(this.code);
  final String code;
  @override
  String toString() => 'VpnFailure($code)';
}

String safeVpnCode(Object? code) =>
    _codes.contains(code) ? code as String : 'native_failure';
const _codes = {
  'native_start_failed',
  'native_storage_unavailable',
  'exclusions_unavailable',
  'system_testing_required',
  'core_config_rejected',
  'core_not_running',
  'tunnel_health_failed',
  'tunnel_https_failed',
  'tunnel_https_status',
  'tunnel_unreachable',
  'transport_unreachable',
  'guard_recovered',
  'vpn_permission_revoked',
  'vpn_permission_unavailable',
  'vpn_permission_restricted',
  'vpn_setup_failed',
  'profile_required',
  'invalid_exclusion',
  'shared_uid_requires_all_packages',
  'tun_duplicate_failed',
  'tun_environment_failed',
  'core_already_running',
  'endpoint_invalid_ip',
  'config_invalid',
  'profile_rejected',
  'exclusions_rejected',
  'statistics_unavailable',
  'native_failure',
  'native_core_unavailable',
  'native_unavailable',
  'service_unavailable',
  'service_access_denied',
  'ipc_unavailable',
  'invalid_native_response',
  'invalid_native_request',
  'permission_denied',
  'permission_cancelled',
  'operation_in_progress',
  'reconnect_required',
  'probe_requires_active_tunnel',
  'unsupported_platform',
  'unsupported',
  'network_unavailable',
  'endpoint_resolution_failed',
  'core_start_failed',
  'tun_establish_failed',
  'health_check_failed',
  'core_failed',
  'invalid_profile',
  'invalid_config',
  'protect_failed',
  'connection_failed',
  'service_not_installed',
  'timeout',
  'ipc_disconnected',
  'channel_closed',
  'mode_unsupported',
  'mode_invalid',
  'mode_switch_requires_connected',
  'mode_profile_mismatch',
  'proxy_setup_failed',
  'proxy_query_failed',
  'proxy_restore_failed',
  'proxy_settings_conflict',
  'proxy_settings_changed',
  'proxy_store_unavailable',
  'proxy_invalid_endpoint',
  'proxy_unavailable',
  'connection_mode_rejected',
  'connection_busy',
  'proxy_exclusions_unsupported',
  'proxy_requires_guard_recovery',
  'proxy_start_failed',
  'proxy_stop_failed',
  'proxy_unreachable',
  'proxy_endpoint_unavailable',
  'proxy_bind_failed',
  'application_routing_unsupported',
  'application_routing_rejected',
  'site_routing_rejected',
  'site_routing_unavailable',
  'site_routing_requires_vpn',
  'site_routing_requires_disconnected',
  'application_icon_unavailable',
  'native_method_unsupported',
  'connection_protection_unavailable',
  'connection_protection_requires_disconnected',
};

final class NativeVpnBridge
    implements
        VpnBridge,
        ConnectionModeBridge,
        ServerReconnectBridge,
        AutomaticSelectionBridge,
        ApplicationRoutingBridge,
        SiteRoutingBridge,
        ApplicationIconBridge,
        ConnectionProtectionBridge,
        VpnPermissionSetupBridge,
        VpnNotificationSettingsBridge {
  NativeVpnBridge({
    MethodChannel? methods,
    EventChannel? stateEvents,
    EventChannel? statsEvents,
  }) : _methods = methods ?? const MethodChannel('exvpn/vpn'),
       _stateEvents = stateEvents ?? const EventChannel('exvpn/vpn_state'),
       _statsEvents = statsEvents ?? const EventChannel('exvpn/vpn_stats');

  final MethodChannel _methods;
  final EventChannel _stateEvents;
  final EventChannel _statsEvents;
  late final Stream<VpnStatus> _states = _stateEvents
      .receiveBroadcastStream()
      .map(decodeStatus);
  late final Stream<TrafficStats> _stats = _statsEvents
      .receiveBroadcastStream()
      .map((raw) {
        final map = _map(raw);
        return TrafficStats(
          uploadBytes: _counter(map['uploadBytes']),
          downloadBytes: _counter(map['downloadBytes']),
        );
      });
  @override
  Stream<VpnStatus> get statuses => _states;
  @override
  Stream<TrafficStats> get traffic => _stats;

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const VpnFailure('native_unavailable');
    } on PlatformException catch (error) {
      throw VpnFailure(safeVpnCode(error.code));
    }
  }

  @override
  Future<VpnStatus> getStatus() async =>
      decodeStatus(await _invoke('getStatus'));

  @override
  bool get supportsConnectionModes =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  bool get supportsServerReconnect =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<void> reconnectServer(ConnectionProfile profile) async {
    if (!supportsServerReconnect) throw const VpnFailure('mode_unsupported');
    await _invoke('reconnect', {
      'profile': profile.toNativeJson(),
      'mode': VpnMode.vpn.name,
    });
  }

  @override
  Future<void> connect(ConnectionProfile profile) async {
    if (supportsConnectionModes) {
      await connectInMode(profile, VpnMode.vpn);
    } else {
      await _invoke('connect', {'profile': profile.toNativeJson()});
    }
  }

  @override
  Future<void> connectInMode(ConnectionProfile profile, VpnMode mode) async {
    if (!supportsConnectionModes) {
      if (mode != VpnMode.vpn) throw const VpnFailure('mode_unsupported');
      await connect(profile);
      return;
    }
    await _invoke('connect', {
      'profile': profile.toNativeJson(),
      'mode': mode.name,
    });
  }

  @override
  Future<void> reconnect(ConnectionProfile profile, VpnMode mode) async {
    if (!supportsConnectionModes) {
      throw const VpnFailure('mode_unsupported');
    }
    await _invoke('reconnect', {
      'profile': profile.toNativeJson(),
      'mode': mode.name,
    });
  }

  @override
  Future<void> disconnect() async {
    await _invoke('disconnect');
  }

  @override
  bool get supportsAutomaticSelection => supportsServerReconnect;

  @override
  Future<void> connectAutomatic(
    ConnectionProfile primary,
    List<ConnectionProfile> candidates,
    VpnMode mode, {
    required bool replace,
  }) async {
    if (!supportsAutomaticSelection ||
        (mode == VpnMode.proxy && !supportsConnectionModes)) {
      throw const VpnFailure('mode_unsupported');
    }
    if (candidates.isEmpty ||
        candidates.length > 32 ||
        candidates.map((p) => p.id).toSet().length != candidates.length ||
        !candidates.any((p) => p.id == primary.id)) {
      throw const VpnFailure('invalid_native_request');
    }
    await _invoke(replace ? 'reconnect' : 'connect', {
      'profile': primary.toNativeJson(),
      'mode': mode.name,
      'automaticProfiles': [for (final p in candidates) p.toNativeJson()],
    });
  }

  @override
  Future<void> clearAutomaticSelection() async {
    await _invoke('clearAutomaticSelection');
  }

  @override
  Future<void> setExclusions(Set<String> applicationIds) async {
    await _invoke('setExclusions', {
      'applications': applicationIds.toList()..sort(),
    });
  }

  @override
  Future<SiteRoutingState> getSiteRouting() async {
    try {
      return SiteRoutingState.fromJson(await _invoke('getSiteRouting'));
    } on FormatException {
      throw const VpnFailure('invalid_native_response');
    } on VpnFailure catch (error) {
      if (error.code == 'native_unavailable' ||
          error.code == 'native_method_unsupported' ||
          error.code == 'unsupported') {
        throw const VpnFailure('site_routing_unavailable');
      }
      rethrow;
    }
  }

  @override
  Future<void> setSiteRouting(SiteRoutingState state) async {
    await _invoke('setSiteRouting', state.toJson());
  }

  @override
  Future<Set<String>> getExclusions() async {
    final raw = await _invoke('getExclusions');
    if (raw is! List || raw.length > 500) {
      throw const VpnFailure('invalid_native_response');
    }
    return raw.map(_text).toSet();
  }

  @override
  Future<ApplicationRoutingPolicy> getApplicationRouting() async {
    try {
      final map = _map(await _invoke('getApplicationRouting'));
      final mode = ApplicationRoutingMode.values
          .where((value) => value.name == map['mode'])
          .firstOrNull;
      final raw = map['applications'];
      if (map.length != 2 || mode == null || raw is! List || raw.length > 500) {
        throw const VpnFailure('invalid_native_response');
      }
      final ids = raw.map(_applicationId).toSet();
      if (ids.length != raw.length) {
        throw const VpnFailure('invalid_native_response');
      }
      return ApplicationRoutingPolicy(mode: mode, applicationIds: ids);
    } on VpnFailure catch (error) {
      if (!_optionalUnavailable(error)) rethrow;
      final ids = await getExclusions();
      return ApplicationRoutingPolicy(
        mode: ids.isEmpty
            ? ApplicationRoutingMode.disabled
            : ApplicationRoutingMode.exclude,
        applicationIds: ids,
      );
    }
  }

  @override
  Future<void> setApplicationRouting(ApplicationRoutingPolicy policy) async {
    final ids = _routingIds(policy.applicationIds);
    try {
      await _invoke('setApplicationRouting', {
        'mode': policy.mode.name,
        'applications': ids,
      });
    } on VpnFailure catch (error) {
      if (!_optionalUnavailable(error)) rethrow;
      if (policy.mode == ApplicationRoutingMode.include) {
        throw const VpnFailure('application_routing_unsupported');
      }
      await setExclusions(
        policy.mode == ApplicationRoutingMode.exclude
            ? policy.applicationIds
            : const {},
      );
    }
  }

  @override
  Future<Uint8List?> getApplicationIcon(String applicationId) async {
    _applicationId(applicationId);
    Object? raw;
    try {
      raw = await _invoke('getApplicationIcon', {'application': applicationId});
    } on VpnFailure catch (error) {
      if (_optionalUnavailable(error) ||
          error.code == 'application_icon_unavailable') {
        return null;
      }
      rethrow;
    }
    if (raw == null) return null;
    if (raw is! Uint8List || raw.length < 33 || raw.length > 64 * 1024) {
      throw const VpnFailure('invalid_native_response');
    }
    const header = [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
    ];
    for (var i = 0; i < header.length; i++) {
      if (raw[i] != header[i]) {
        throw const VpnFailure('invalid_native_response');
      }
    }
    final data = ByteData.sublistView(raw);
    if (data.getUint32(16) != 64 || data.getUint32(20) != 64) {
      throw const VpnFailure('invalid_native_response');
    }
    return Uint8List.fromList(raw);
  }

  @override
  Future<List<ApplicationIdentity>> listApplications() async {
    final raw = await _invoke('listApplications');
    if (raw is! List || raw.length > 10000) {
      throw const VpnFailure('invalid_native_response');
    }
    return raw
        .map((item) {
          final map = _map(item);
          return ApplicationIdentity(
            id: _text(map['id']),
            displayName: _text(map['displayName']),
            sharedIdentityGroup: _optionalText(map['sharedIdentityGroup']),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<ProbeResult> probe(ConnectionProfile profile) async {
    final map = _map(
      await _invoke('probe', {'profile': profile.toNativeJson()}),
    );
    if (map['reachable'] is! bool) {
      throw const VpnFailure('invalid_native_response');
    }
    return ProbeResult(
      reachable: map['reachable'] as bool,
      latency: map['latencyMs'] == null
          ? null
          : Duration(milliseconds: _counter(map['latencyMs'])),
      errorCode: map['errorCode'] == null
          ? null
          : safeVpnCode(map['errorCode']),
    );
  }

  @override
  Future<String> coreVersion() async => _text(await _invoke('coreVersion'));
  @override
  Future<void> openSystemProtectionSettings() async {
    await _invoke('openSystemProtectionSettings');
  }

  @override
  Future<VpnPermissionSetup> getVpnPermissionSetup() async {
    try {
      return VpnPermissionSetup.decode(await _invoke('getVpnPermissionSetup'));
    } on FormatException {
      throw const VpnFailure('invalid_native_response');
    }
  }

  @override
  Future<void> openAppPermissionSettings() async {
    await _invoke('openAppPermissionSettings');
  }

  @override
  Future<NotificationPermissionState> getNotificationPermission() async =>
      switch (await _invoke('getNotificationPermission')) {
        'granted' => NotificationPermissionState.granted,
        'required' => NotificationPermissionState.required,
        _ => throw const VpnFailure('invalid_native_response'),
      };

  @override
  Future<void> openNotificationSettings() async {
    await _invoke('openNotificationSettings');
  }

  @override
  Future<ConnectionProtection> getConnectionProtection() async =>
      decodeConnectionProtection(await _invoke('getConnectionProtection'));

  @override
  Future<ConnectionProtection> setConnectionProtection(bool enabled) async =>
      decodeConnectionProtection(
        await _invoke('setConnectionProtection', {'enabled': enabled}),
      );

  static ConnectionProtection decodeConnectionProtection(Object? raw) {
    final map = _map(raw);
    const keys = {'supported', 'enabled', 'active', 'systemManaged'};
    if (map.length != keys.length ||
        !keys.every(map.containsKey) ||
        map['supported'] is! bool ||
        map['active'] is! bool ||
        map['systemManaged'] is! bool ||
        (map['enabled'] != null && map['enabled'] is! bool) ||
        (map['enabled'] == null && map['systemManaged'] != true) ||
        (map['active'] == true && map['supported'] != true)) {
      throw const VpnFailure('invalid_native_response');
    }
    return ConnectionProtection(
      supported: map['supported'] as bool,
      enabled: map['enabled'] as bool?,
      active: map['active'] as bool,
      systemManaged: map['systemManaged'] as bool,
    );
  }

  static VpnStatus decodeStatus(Object? raw) {
    final map = _map(raw);
    final phase = VpnPhase.values
        .where((value) => value.name == map['phase'])
        .firstOrNull;
    if (phase == null || map['processCrashProtection'] is! bool) {
      throw const VpnFailure('invalid_native_response');
    }
    final id = _optionalText(map['activeProfileId']);
    final epoch = map['connectedAt'];
    if (epoch != null &&
        (epoch is! int || epoch < 0 || epoch > 8640000000000000)) {
      throw const VpnFailure('invalid_native_response');
    }
    if (phase == VpnPhase.connected && (id == null || epoch == null)) {
      throw const VpnFailure('invalid_native_response');
    }
    final mode = map.containsKey('mode')
        ? VpnMode.values.where((value) => value.name == map['mode']).firstOrNull
        : VpnMode.vpn;
    if (mode == null ||
        (map.containsKey('systemProxySupported') &&
            map['systemProxySupported'] is! bool) ||
        (map.containsKey('cleanupRequired') &&
            map['cleanupRequired'] is! bool) ||
        (map.containsKey('automaticSelection') &&
            map['automaticSelection'] is! bool)) {
      throw const VpnFailure('invalid_native_response');
    }
    return VpnStatus(
      phase: phase,
      processCrashProtection: map['processCrashProtection'] as bool,
      activeProfileId: id,
      connectedAt: epoch == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(epoch as int),
      errorCode: map['errorCode'] == null
          ? null
          : safeVpnCode(map['errorCode']),
      mode: mode,
      systemProxySupported: map['systemProxySupported'] == true,
      cleanupRequired: map['cleanupRequired'] == true,
      automaticSelection: map['automaticSelection'] == true,
    );
  }
}

Map<Object?, Object?> _map(Object? raw) {
  if (raw is! Map) throw const VpnFailure('invalid_native_response');
  return raw;
}

String _text(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 4096) {
    throw const VpnFailure('invalid_native_response');
  }
  return raw;
}

String? _optionalText(Object? raw) => raw == null ? null : _text(raw);
int _counter(Object? raw) {
  if (raw is! int || raw < 0) throw const VpnFailure('invalid_native_response');
  return raw;
}

bool _optionalUnavailable(VpnFailure error) =>
    error.code == 'native_unavailable' ||
    error.code == 'native_method_unsupported' ||
    error.code == 'unsupported';

String _applicationId(Object? raw) {
  final id = _text(raw);
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) {
    throw const VpnFailure('invalid_native_response');
  }
  return id;
}

List<String> _routingIds(Set<String> ids) {
  if (ids.length > 128) throw const VpnFailure('invalid_exclusion');
  try {
    return ids.map(_applicationId).toList()..sort();
  } on VpnFailure {
    throw const VpnFailure('invalid_exclusion');
  }
}
