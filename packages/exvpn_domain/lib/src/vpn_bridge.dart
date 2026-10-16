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

final class VpnStatus {
  const VpnStatus({
    required this.phase,
    required this.processCrashProtection,
    this.activeProfileId,
    this.connectedAt,
    this.errorCode,
  });
  final VpnPhase phase;

  /// True only after the native backend verifies OS-level protection.
  final bool processCrashProtection;
  final String? activeProfileId;
  final DateTime? connectedAt;

  /// Stable diagnostic code; never a raw exception or core configuration.
  final String? errorCode;
}

final class ApplicationIdentity {
  const ApplicationIdentity({
    required this.id,
    required this.displayName,
    this.sharedIdentityGroup,
  });

  /// Android package name; Windows canonical absolute executable path.
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
