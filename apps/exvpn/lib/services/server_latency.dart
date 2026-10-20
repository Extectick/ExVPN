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

typedef _Endpoint = (String, int, bool);

/// Event-driven endpoint checks: no polling timer, bounded parallelism/cache.
/// Automatic work replaces its queue with the currently visible profiles.
final class ServerLatencyController extends ChangeNotifier {
  ServerLatencyController({
    LatencyProbe? probe,
    DateTime Function()? now,
    this.canProbe,
  }) : _probe = probe ?? platform.probeServerLatency,
       _now = now ?? DateTime.now;

  static const _timeout = Duration(seconds: 3);
  static const _concurrency = 2;
  static const cacheTtl = Duration(minutes: 5);
  static const failureTtl = Duration(seconds: 30);
  static const maxCachedEndpoints = 256;
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
  final DateTime Function() _now;
  final bool Function()? canProbe;
  final Map<String, LatencySample> _results = {};
  final Set<String> _checking = {};
  final _cache = <_Endpoint, ({LatencySample sample, DateTime at})>{};
  final _queue = <_Endpoint, ConnectionProfile>{};
  final _inflight = <_Endpoint>{};
  final _cancellations = <void Function()>{};
  Map<String, ConnectionProfile> _targets = {};
  final _aliases = <_Endpoint, List<ConnectionProfile>>{};
  late final Map<String, LatencySample> _resultsView = UnmodifiableMapView(
    _results,
  );
  late final Set<String> _checkingView = UnmodifiableSetView(_checking);
  Future<void>? _running;
  bool _busy = false;
  bool _disposed = false;

  bool get _allowed => !_disposed && (canProbe?.call() ?? true);
  bool get busy => _busy;
  Map<String, LatencySample> get results => _resultsView;
  Set<String> get checking => _checkingView;

  static bool _supportsTcp(ConnectionProfile p) =>
      p.protocol != ProxyProtocol.hysteria2 &&
      p.protocol != ProxyProtocol.wireguard &&
      _tcpTransports.contains(p.transport.type);
  static _Endpoint _endpoint(ConnectionProfile p) =>
      (p.server.toLowerCase(), p.port, _supportsTcp(p));

  /// Explicit all-server action bypasses the cache; automatic requests do not.
  Future<void> checkAll(Iterable<ConnectionProfile> profiles) {
    if (_disposed || _busy) return _running ?? Future.value();
    return _replaceTargets(profiles, force: true);
  }

  Future<void> checkVisible(Iterable<ConnectionProfile> profiles) =>
      _replaceTargets(profiles, force: false);

  Future<void> _replaceTargets(
    Iterable<ConnectionProfile> profiles, {
    required bool force,
  }) {
    if (_disposed) return Future.value();
    _targets = {for (final p in profiles) p.id: p};
    _aliases.clear();
    for (final profile in _targets.values) {
      (_aliases[_endpoint(profile)] ??= []).add(profile);
    }
    _queue.clear();
    _checking.clear();
    for (final profile in _targets.values) {
      final key = _endpoint(profile);
      final cached = _cache.remove(key);
      if (cached != null) _cache[key] = cached;
      final ttl = cached?.sample.milliseconds != null ? cacheTtl : failureTtl;
      if (!force && cached != null && _now().difference(cached.at) < ttl) {
        _remember(profile.id, cached.sample);
      } else {
        _checking.add(profile.id);
        if (!_inflight.contains(key)) _queue.putIfAbsent(key, () => profile);
      }
    }
    if (!_allowed) {
      pause();
      return _running ?? Future.value();
    }
    if (_running != null) {
      notifyListeners();
      return _running!;
    }
    _busy = _queue.isNotEmpty;
    notifyListeners();
    if (!_busy) return Future.value();
    return _running = Future<void>.microtask(_run);
  }

  void _remember(String id, LatencySample sample) {
    _results.remove(id);
    _results[id] = sample;
    while (_results.length > maxCachedEndpoints * 2) {
      _results.remove(_results.keys.first);
    }
  }

  Future<void> _run() async {
    Future<void> work() async {
      while (_allowed && _queue.isNotEmpty) {
        final key = _queue.keys.first;
        final profile = _queue.remove(key)!;
        _inflight.add(key);
        final sample = await _measure(profile);
        _inflight.remove(key);
        if (_disposed) return;
        _cache.remove(key);
        _cache[key] = (sample: sample, at: _now());
        while (_cache.length > maxCachedEndpoints) {
          _cache.remove(_cache.keys.first);
        }
        for (final target in _aliases[key] ?? const <ConnectionProfile>[]) {
          _remember(target.id, sample);
          _checking.remove(target.id);
        }
        notifyListeners();
      }
    }

    try {
      await Future.wait([for (var i = 0; i < _concurrency; i++) work()]);
    } finally {
      _running = null;
      if (!_disposed) {
        _queue.clear();
        _checking.clear();
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// In-flight TCP/DNS work retains its native deadline; no new work is started.
  void pause() {
    _queue.clear();
    _targets = {};
    _aliases.clear();
    _checking.clear();
    if (!_disposed) notifyListeners();
  }

  Future<LatencySample> _measure(ConnectionProfile profile) async {
    // Check this before a custom probe as well: a TCP timeout must not label a
    // healthy UDP-only endpoint as unreachable.
    if (profile.protocol == ProxyProtocol.hysteria2 ||
        profile.protocol == ProxyProtocol.wireguard ||
        !_tcpTransports.contains(profile.transport.type)) {
      return const LatencySample(null, 'latency_transport_unsupported');
    }
    try {
      final cancel = Completer<ProbeResult>();
      void abort() {
        if (!cancel.isCompleted) {
          cancel.complete(const ProbeResult(reachable: false));
        }
      }

      _cancellations.add(abort);
      final ProbeResult result;
      try {
        result = await Future.any([
          Future<ProbeResult>.sync(() => _probe(profile)),
          cancel.future,
        ]).timeout(_timeout);
      } finally {
        _cancellations.remove(abort);
      }

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
    _queue.clear();
    _targets = {};
    _aliases.clear();
    _cache.clear();
    _results.clear();
    for (final abort in _cancellations.toList()) {
      abort();
    }
    _cancellations.clear();
    super.dispose();
  }
}
