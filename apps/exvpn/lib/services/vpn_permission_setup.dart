// SPDX-License-Identifier: Apache-2.0

enum VpnPermissionState { granted, required, restricted, unavailable }

enum NotificationPermissionState { granted, required }

enum AndroidVendor { android, xiaomi }

/// A small, public-API permission snapshot, never an inventory of other VPNs.
final class VpnPermissionSetup {
  const VpnPermissionSetup({
    required this.vpn,
    required this.notifications,
    required this.vendor,
  });

  const VpnPermissionSetup.unavailable()
    : vpn = VpnPermissionState.unavailable,
      notifications = NotificationPermissionState.required,
      vendor = AndroidVendor.android;

  final VpnPermissionState vpn;
  final NotificationPermissionState notifications;
  final AndroidVendor vendor;

  factory VpnPermissionSetup.decode(Object? value) {
    const keys = {'schema', 'vpn', 'notifications', 'vendor'};
    if (value is! Map ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['schema'] is! int ||
        value['schema'] != 1) {
      throw const FormatException('invalid_permission_setup');
    }
    final vpn = VpnPermissionState.values
        .where((entry) => entry.name == value['vpn'])
        .firstOrNull;
    final notifications = NotificationPermissionState.values
        .where((entry) => entry.name == value['notifications'])
        .firstOrNull;
    final vendor = AndroidVendor.values
        .where((entry) => entry.name == value['vendor'])
        .firstOrNull;
    if (vpn == null || notifications == null || vendor == null) {
      throw const FormatException('invalid_permission_setup');
    }
    return VpnPermissionSetup(
      vpn: vpn,
      notifications: notifications,
      vendor: vendor,
    );
  }
}

/// Optional app-local capability; existing/platform-fake VpnBridge contracts
/// do not gain a mandatory method when Android adds its recovery flow.
abstract interface class VpnPermissionSetupBridge {
  Future<VpnPermissionSetup> getVpnPermissionSetup();
  Future<void> openAppPermissionSettings();
}

bool isVpnPermissionSetupError(String? code) => const {
  'permission_denied',
  'vpn_permission_unavailable',
  'vpn_permission_restricted',
}.contains(code);
