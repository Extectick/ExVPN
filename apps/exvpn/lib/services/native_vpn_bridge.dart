import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/services.dart';

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
};

final class NativeVpnBridge implements VpnBridge {
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
  Future<void> connect(ConnectionProfile profile) async {
    await _invoke('connect', {'profile': profile.toNativeJson()});
  }

  @override
  Future<void> disconnect() async {
    await _invoke('disconnect');
  }

  @override
  Future<void> setExclusions(Set<String> applicationIds) async {
    await _invoke('setExclusions', {
      'applications': applicationIds.toList()..sort(),
    });
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
