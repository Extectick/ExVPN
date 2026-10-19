import 'dart:typed_data';

import 'profile.dart';

enum VpnPhase {
  disconnected,
  requestingPermission,
  connecting,
  connected,
  reconnecting,
  blocked,
  error,
}

enum VpnMode { proxy, vpn }

enum ApplicationRoutingMode { disabled, exclude, include }

/// Local application policy. Disabled retains the selection without applying it.
final class ApplicationRoutingPolicy {
  ApplicationRoutingPolicy({
    required this.mode,
    Set<String> applicationIds = const {},
  }) : applicationIds = Set<String>.unmodifiable(applicationIds);

  final ApplicationRoutingMode mode;
  final Set<String> applicationIds;

  @override
  bool operator ==(Object other) =>
      other is ApplicationRoutingPolicy &&
      mode == other.mode &&
      applicationIds.length == other.applicationIds.length &&
      applicationIds.containsAll(other.applicationIds);

  @override
  int get hashCode =>
      Object.hash(mode, Object.hashAllUnordered(applicationIds));
}

final class VpnStatus {
  const VpnStatus({
    required this.phase,
    required this.processCrashProtection,
    this.activeProfileId,
    this.connectedAt,
    this.errorCode,
    this.mode = VpnMode.vpn,
    this.systemProxySupported = false,
    this.cleanupRequired = false,
    this.automaticSelection = false,
  });
  final VpnPhase phase;

  /// True only after the native backend verifies OS-level protection.
  final bool processCrashProtection;
  final String? activeProfileId;
  final DateTime? connectedAt;

  /// Stable diagnostic code; never a raw exception or core configuration.
  final String? errorCode;
  final VpnMode mode;
  final bool systemProxySupported;

  /// Local native recovery is pending even when the service cannot be reached.
  final bool cleanupRequired;

  /// Authoritative native group policy, independent of the UI lifetime.
  final bool automaticSelection;
}

final class ApplicationIdentity {
  const ApplicationIdentity({
    required this.id,
    required this.displayName,
    this.sharedIdentityGroup,
  });

  /// Android package name; Windows canonical executable path or a native
  /// recognized application-family anchor (for example, Discord). Treat this
  /// identity as opaque: a family anchor need not itself be an installed file.
  final String id;
  final String displayName;
  final String? sharedIdentityGroup;
}

final class TrafficStats {
  const TrafficStats({required this.uploadBytes, required this.downloadBytes});
  final int uploadBytes;
  final int downloadBytes;
}

final class ProbeResult {
  const ProbeResult({required this.reachable, this.latency, this.errorCode});
  final bool reachable;
  final Duration? latency;
  final String? errorCode;
}

/// Implementations must never report connected using a timer or mock backend.
/// Secrets may cross only the authenticated platform/service boundary.
abstract interface class VpnBridge {
  Stream<VpnStatus> get statuses;
  Stream<TrafficStats> get traffic;
  Future<VpnStatus> getStatus();
  Future<void> connect(ConnectionProfile profile);
  Future<void> disconnect();
  Future<List<ApplicationIdentity>> listApplications();
  Future<void> setExclusions(Set<String> applicationIds);
  Future<Set<String>> getExclusions();
  Future<ProbeResult> probe(ConnectionProfile profile);
  Future<String> coreVersion();
  Future<void> openSystemProtectionSettings();
}

/// Optional native capability; legacy/Android bridges keep the VPN-only API.
abstract interface class ConnectionModeBridge {
  bool get supportsConnectionModes;
  Future<void> connectInMode(ConnectionProfile profile, VpnMode mode);
  Future<void> reconnect(ConnectionProfile profile, VpnMode mode);
}

/// A platform may replace its VPN server while retaining the TUN even when it
/// has no system-proxy mode (Android). Never emulate this with UI disconnect.
abstract interface class ServerReconnectBridge {
  bool get supportsServerReconnect;
  Future<void> reconnectServer(ConnectionProfile profile);
}

/// Optional service-owned primary/backup selection. Candidates are explicitly
/// chosen locally, bounded and validated at the native boundary. Configuration
/// from a subscription never enables this policy automatically.
abstract interface class AutomaticSelectionBridge {
  bool get supportsAutomaticSelection;
  Future<void> connectAutomatic(
    ConnectionProfile primary,
    List<ConnectionProfile> candidates,
    VpnMode mode, {
    required bool replace,
  });

  /// Cancel future automatic changes, preserving the active tunnel and guard.
  Future<void> clearAutomaticSelection();
}

/// Optional native policy support. Legacy bridges can express exclusions only.
abstract interface class ApplicationRoutingBridge {
  Future<ApplicationRoutingPolicy> getApplicationRouting();
  Future<void> setApplicationRouting(ApplicationRoutingPolicy policy);
}

/// Optional, cosmetic native icons. Unsupported or missing icons return null.
abstract interface class ApplicationIconBridge {
  Future<Uint8List?> getApplicationIcon(String applicationId);
}
