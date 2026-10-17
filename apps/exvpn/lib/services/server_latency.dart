import 'dart:async';
import 'dart:collection';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';

import 'server_latency_stub.dart'
    if (dart.library.io) 'server_latency_native.dart'
    as platform;

typedef LatencyProbe = Future<ProbeResult> Function(ConnectionProfile profile);

/// A TCP endpoint measurement, never evidence that a VPN tunnel works.
final class LatencySample {
  const LatencySample(this.milliseconds, this.errorCode);

  final int? milliseconds;
  final String? errorCode;
}

/// Measures a snapshot of all profiles with at most four probes in flight.
///
/// Measurements include endpoint resolution and the TCP connection handshake.
/// They do not authenticate a server, exchange user traffic, or start a VPN.
/// UDP-only Hysteria2 endpoints have no corresponding TCP measurement.
final class ServerLatencyController extends ChangeNotifier {
  ServerLatencyController({LatencyProbe? probe})
    : _probe = probe ?? platform.probeServerLatency;

  static const _timeout = Duration(seconds: 3);
  static const _concurrency = 4;
  static const _tcpTransports = {'tcp', 'raw', 'ws', 'grpc', 'xhttp'};
  static const _safeCodes = {
    'latency_transport_unsupported',
    'latency_platform_unsupported',
    'latency_timeout',
    'latency_unreachable',
    'latency_invalid_profile',
    'latency_failed',
  };

  final LatencyProbe _probe;
  final Map<String, LatencySample> _results = {};
  final Set<String> _checking = {};
  late final Map<String, LatencySample> _resultsView = UnmodifiableMapView(
    _results,
  );
  late final Set<String> _checkingView = UnmodifiableSetView(_checking);
  bool _busy = false;
  bool _disposed = false;

  bool get busy => _busy;
  Map<String, LatencySample> get results => _resultsView;

  /// Includes queued and active profiles until each measurement finishes.
  Set<String> get checking => _checkingView;

  Future<void> checkAll(Iterable<ConnectionProfile> profiles) async {
    if (_disposed || _busy) return;

    final unique = <String, ConnectionProfile>{};
    for (final profile in profiles) {
      unique.putIfAbsent(profile.id, () => profile);
    }
    final snapshot = unique.values.toList(growable: false);
    _results
      ..clear()
      ..addEntries(
        unique.keys.map((id) => MapEntry(id, const LatencySample(null, null))),
      );
    _checking
      ..clear()
      ..addAll(unique.keys);
    _busy = snapshot.isNotEmpty;
    notifyListeners();
    if (!_busy || _disposed) return;

    var next = 0;
    Future<void> work() async {
      while (!_disposed && next < snapshot.length) {
        final profile = snapshot[next++];
        final sample = await _measure(profile);
        if (_disposed) return;
        _results[profile.id] = sample;
        _checking.remove(profile.id);
        notifyListeners();
      }
    }

    try {
      await Future.wait([
        for (
          var worker = 0;
          worker < _concurrency && worker < snapshot.length;
          worker++
        )
          work(),
      ]);
    } finally {
      if (!_disposed) {
        _busy = false;
        _checking.clear();
        notifyListeners();
      }
    }
  }

  Future<LatencySample> _measure(ConnectionProfile profile) async {
    // Check this before a custom probe as well: a TCP timeout must not label a
    // healthy UDP-only endpoint as unreachable.
    if (profile.protocol == ProxyProtocol.hysteria2 ||
        !_tcpTransports.contains(profile.transport.type)) {
      return const LatencySample(null, 'latency_transport_unsupported');
    }
    try {
      final result = await _probe(profile).timeout(_timeout);
      final latency = result.latency;
      if (result.reachable && latency != null && !latency.isNegative) {
        return LatencySample(latency.inMilliseconds, null);
      }
      final code = _safeCodes.contains(result.errorCode)
          ? result.errorCode
          : 'latency_failed';
      return LatencySample(null, code);
    } on TimeoutException {
      return const LatencySample(null, 'latency_timeout');
    } catch (_) {
      return const LatencySample(null, 'latency_failed');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _busy = false;
    _checking.clear();
    super.dispose();
  }
}
