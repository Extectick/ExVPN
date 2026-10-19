// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/widgets.dart';

import 'app_updates.dart';
import 'dart_updates.dart';
import 'native_vpn_bridge.dart';
import 'safe_diagnostics.dart';
import 'subscription_persistence.dart';
import 'vpn_controller.dart';

/// Session-only structured events. Never accepts raw log lines or exceptions.
/// Each producer constructs its own closed schema from typed controller state.
class ClientLogs extends ChangeNotifier {
  ClientLogs({
    required AppController controller,
    VpnController? vpn,
    AppUpdatesController? appUpdates,
    DartUpdatesController? dartUpdates,
    SubscriptionPersistence? persistence,
    DateTime Function()? now,
    Duration cleanupInterval = const Duration(minutes: 1),
  }) : _controller = controller,
       _vpn = vpn,
       _appUpdates = appUpdates,
       _dartUpdates = dartUpdates,
       _persistence = persistence,
       _now = now ?? DateTime.now {
    if (cleanupInterval <= Duration.zero) {
      throw ArgumentError('cleanupInterval must be positive');
    }
    _started = _now();
    _changes = controller.changes.listen((_) => _captureSubscriptions());
    vpn?.addListener(_captureVpn);
    appUpdates?.addListener(_captureAppUpdates);
    dartUpdates?.addListener(_captureDartUpdates);
    persistence?.addListener(_capturePersistence);
    _captureSubscriptions();
    _captureVpn();
    _captureAppUpdates();
    _captureDartUpdates();
    _capturePersistence();
    _cleanup = Timer.periodic(cleanupInterval, (_) {
      if (_prune(_now())) notifyListeners();
    });
  }

  static const maxEvents = 64;
  static const maxAge = Duration(minutes: 30);
  static const maxReportBytes = 64 * 1024;
  final AppController _controller;
  final VpnController? _vpn;
  final AppUpdatesController? _appUpdates;
  final DartUpdatesController? _dartUpdates;
  final SubscriptionPersistence? _persistence;
  final DateTime Function() _now;
  late final DateTime _started;
  late final StreamSubscription<void> _changes;
  late final Timer _cleanup;
  final List<_LogEvent> _events = [];
  final Map<String, String> _last = {};
  bool _disposed = false;

  int get eventCount {
    _prune(_now());
    return _events.length;
  }

  void clear() {
    if (_disposed) return;
    _events.clear();
    // Keep dedup snapshots: routine stats must not repopulate a cleared log.
    notifyListeners();
  }

  void _record(String source, Map<String, Object?> state) {
    if (_disposed) return;
    final now = _now();
    final removed = _prune(now);
    final fingerprint = jsonEncode(state);
    if (_last[source] == fingerprint) {
      if (removed) notifyListeners();
      return;
    }
    _last[source] = fingerprint;
    _events.add(_LogEvent(now, source, Map.unmodifiable(state)));
    if (_events.length > maxEvents) _events.removeAt(0);
    notifyListeners();
  }

  bool _prune(DateTime now) {
    final previous = _events.length;
    _events.removeWhere((event) => now.difference(event.at) >= maxAge);
    return previous != _events.length;
  }

  void _captureSubscriptions() {
    final groups = _controller.groups;
    final codes = {
      for (final group in groups)
        for (final issue in group.issues) issue.code.name,
    }.toList()..sort();
    _record('subscriptions', {
      'groups': _count(groups.length),
      'profiles': _count(groups.fold<int>(0, (n, g) => n + g.servers.length)),
      'issues': _count(groups.fold<int>(0, (n, g) => n + g.issues.length)),
      'issueCodes': codes,
      'selectedProtocol': _controller.selectedServer?.profile.protocol.name,
      'automaticGroupSelected': _controller.selectedAutomaticGroupId != null,
    });
  }

  void _captureVpn() {
    final vpn = _vpn;
    if (vpn == null) return;
    final error = vpn.lastErrorCode ?? vpn.status.errorCode;
    _record('vpn', {
      'phase': vpn.status.phase.name,
      'mode': vpn.mode.name,
      'initialized': vpn.initialized,
      'processCrashProtection': vpn.status.processCrashProtection,
      'cleanupRequired': vpn.status.cleanupRequired,
      'automaticSelection': vpn.automaticSelectionEnabled,
      'routingMode': vpn.applicationRouting.mode.name,
      'errorCode': error == null ? null : safeVpnCode(error),
      'protectionSupported': vpn.connectionProtection.supported,
      'protectionEnabled': vpn.connectionProtection.enabled,
      'protectionActive': vpn.connectionProtection.active,
      'protectionSystemManaged': vpn.connectionProtection.systemManaged,
      'protectionBusy': vpn.protectionBusy,
      'protectionError': vpn.protectionError == null
          ? null
          : safeVpnCode(vpn.protectionError),
    });
  }

  void _captureAppUpdates() {
    final updates = _appUpdates;
    if (updates == null) return;
    _record('appUpdates', {
      'phase': updates.phase.name,
      'kind': updates.kind?.name,
      'version': _version(updates.availableVersion),
      'errorCode': updates.errorCode == null
          ? null
          : safeAppUpdateCode(updates.errorCode),
    });
  }

  void _captureDartUpdates() {
    final updates = _dartUpdates;
    if (updates == null) return;
    _record('dartUpdates', {
      'operation': updates.operation.name,
      'status': updates.status?.name,
      'available': updates.available,
      'current': _revision(updates.snapshot?.current),
      'next': _revision(updates.snapshot?.next),
      'restartRequired': updates.restartRequired,
      'track': _channel(updates.track),
      'errorCode': updates.error?.name,
    });
  }

  void _capturePersistence() {
    final persistence = _persistence;
    if (persistence == null) return;
    _record('storage', {
      'saving': persistence.saving,
      'pending': persistence.pending,
      'errorCode': persistence.error?.name,
    });
  }

  /// Rebuild the existing schema1 using its own allowlist, dropping every
  /// unknown key/value before nesting it in the bounded schema2 report.
  String buildReport(String diagnostics) {
    if (_disposed || diagnostics.length > 16 * 1024) {
      throw const ClientLogsReportFailure();
    }
    final Map<String, dynamic> fields;
    try {
      final decoded = jsonDecode(diagnostics);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != 1 ||
          decoded['application'] != 'ExVPN') {
        throw const ClientLogsReportFailure();
      }
      fields = decoded;
    } catch (_) {
      throw const ClientLogsReportFailure();
    }
    final rawUpdates = fields['updates'];
    final updates = rawUpdates is Map<String, dynamic>
        ? rawUpdates
        : const <String, dynamic>{};
    final phase = VpnPhase.values
        .where((value) => value.name == fields['vpnPhase'])
        .firstOrNull;
    final core = fields['coreVersion'];
    final safe = jsonDecode(
      safeDiagnostics(
        status: phase == null
            ? null
            : VpnStatus(
                phase: phase,
                processCrashProtection:
                    fields['processCrashProtection'] == true,
              ),
        platform: fields['platform'] is String ? fields['platform'] : 'unknown',
        coreVersion:
            core is String &&
                _fullMatch(
                  RegExp(r'\d{1,4}\.\d{1,3}\.\d{1,3}(?:-exvpn\.[1-9]\d{0,3})?'),
                  core,
                )
            ? core
            : null,
        errorCode: fields['errorCode'] == null
            ? null
            : safeVpnCode(fields['errorCode']),
        secureStorageAvailable: fields['secureStorageAvailable'] == true,
        dataRevision: _revision(updates['dataRevision']),
        dataChannel: _channel(updates['dataChannel']),
        dartUpdatesAvailable: _boolean(updates['dartAvailable']),
        currentDartPatch: _revision(updates['currentDartPatch']),
        nextDartPatch: _revision(updates['nextDartPatch']),
        dartRestartRequired: _boolean(updates['dartRestartRequired']),
        dartUpdateTrack: _channel(updates['dartTrack']),
      ),
    );
    final now = _now();
    _prune(now);
    final included = List<_LogEvent>.of(_events);
    while (true) {
      final report = const JsonEncoder.withIndent('  ').convert({
        'schema': 2,
        'diagnostics': safe,
        'session': {
          'elapsedMs': _elapsed(now),
          'retentionMinutes': maxAge.inMinutes,
          'maxEvents': maxEvents,
          'eventsOmitted': _events.length - included.length,
        },
        'events': [
          for (final event in included)
            {
              'elapsedMs': _elapsed(event.at),
              'source': event.source,
              'state': event.state,
            },
        ],
      });
      if (utf8.encode(report).length <= maxReportBytes) return report;
      if (included.isEmpty) throw const ClientLogsReportFailure();
      included.removeAt(0);
    }
  }

  int _elapsed(DateTime at) =>
      at.difference(_started).inMilliseconds.clamp(0, 0x7fffffff);

  @override
  void dispose() {
    _disposed = true;
    _cleanup.cancel();
    unawaited(_changes.cancel());
    _vpn?.removeListener(_captureVpn);
    _appUpdates?.removeListener(_captureAppUpdates);
    _dartUpdates?.removeListener(_captureDartUpdates);
    _persistence?.removeListener(_capturePersistence);
    _events.clear();
    _last.clear();
    super.dispose();
  }
}

class ClientLogsReportFailure implements Exception {
  const ClientLogsReportFailure();
  @override
  String toString() => 'Client logs unavailable';
}

class ClientLogsScope extends InheritedNotifier<ClientLogs> {
  const ClientLogsScope({
    super.key,
    required ClientLogs logs,
    required super.child,
  }) : super(notifier: logs);

  static ClientLogs? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ClientLogsScope>()?.notifier;
}

class _LogEvent {
  const _LogEvent(this.at, this.source, this.state);
  final DateTime at;
  final String source;
  final Map<String, Object?> state;
}

int _count(int value) => value.clamp(0, 1000000);
int? _revision(Object? value) =>
    value is int && value > 0 && value <= 0x7fffffff ? value : null;
bool? _boolean(Object? value) => value is bool ? value : null;
String? _channel(Object? value) =>
    const {'stable', 'beta', 'staging'}.contains(value)
    ? value as String
    : null;
bool _fullMatch(RegExp pattern, String value) =>
    pattern.firstMatch(value)?.group(0) == value;
String? _version(String? value) =>
    value != null &&
        value.length <= 40 &&
        _fullMatch(
          RegExp(r'\d{1,4}\.\d{1,4}\.\d{1,4}(?:\+[1-9]\d{0,8})?'),
          value,
        )
    ? value
    : null;
