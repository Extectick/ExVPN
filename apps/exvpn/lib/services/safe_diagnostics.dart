import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';

import 'native_vpn_bridge.dart';
import '../build_identity.dart';

/// A small explicit schema, never a dump of app/native state. No profiles,
/// addresses, IDs, URLs, package paths, traffic logs or raw errors enter it.
String safeDiagnostics({
  required VpnStatus? status,
  required String platform,
  String? coreVersion,
  String? errorCode,
  required bool secureStorageAvailable,
  int? dataRevision,
  String? dataChannel,
  bool? dartUpdatesAvailable,
  int? currentDartPatch,
  int? nextDartPatch,
  bool? dartRestartRequired,
  String? dartUpdateTrack,
}) {
  final core =
      coreVersion != null &&
          RegExp(r'^\d{1,4}\.\d{1,3}\.\d{1,3}(?:-exvpn\.[1-9]\d{0,3})?$')
              .hasMatch(coreVersion)
      ? coreVersion
      : null;
  final os =
      const {
        'android',
        'windows',
        'linux',
        'iOS',
        'macOS',
        'web',
      }.contains(platform)
      ? platform
      : 'unknown';
  return const JsonEncoder.withIndent('  ').convert({
    'schema': 1,
    'application': 'ExVPN',
    'version': appVersionLabel,
    'platform': os,
    'coreVersion': core,
    'vpnPhase': status?.phase.name ?? 'unavailable',
    'processCrashProtection': status?.processCrashProtection ?? false,
    'errorCode': errorCode == null ? null : safeVpnCode(errorCode),
    'secureStorageAvailable': secureStorageAvailable,
    'updates': {
      'dataRevision': _safeRevision(dataRevision),
      'dataChannel': _safeChannel(dataChannel),
      'dartAvailable': dartUpdatesAvailable,
      'currentDartPatch': _safeRevision(currentDartPatch),
      'nextDartPatch': _safeRevision(nextDartPatch),
      'dartRestartRequired': dartRestartRequired,
      'dartTrack': _safeChannel(dartUpdateTrack),
    },
  });
}

int? _safeRevision(int? value) =>
    value != null && value > 0 && value <= 0x7fffffff ? value : null;

String? _safeChannel(String? value) =>
    const {'stable', 'beta', 'staging'}.contains(value) ? value : null;
