import 'dart:async';
import 'dart:io';

import 'package:exvpn_domain/exvpn_domain.dart';

const _deadline = Duration(seconds: 3);
const _maxActiveOperations = 4;
var _activeOperations = 0;

/// TCP endpoint latency only. No TLS, application payload, or VPN bridge call.
Future<ProbeResult> probeServerLatency(ConnectionProfile profile) async {
  const tcpTransports = {'tcp', 'raw', 'ws', 'grpc', 'xhttp'};
  if (profile.protocol == ProxyProtocol.hysteria2 ||
      profile.protocol == ProxyProtocol.wireguard ||
      !tcpTransports.contains(profile.transport.type)) {
    return const ProbeResult(
      reachable: false,
      errorCode: 'latency_transport_unsupported',
    );
  }
  if (profile.server.isEmpty || profile.port < 1 || profile.port > 65535) {
    return const ProbeResult(
      reachable: false,
      errorCode: 'latency_invalid_profile',
    );
  }

  // OS DNS lookups are not cancellable. Retain their slots until the original
  // operations settle, even when a caller has already received a timeout.
  // Do not create a queue or launch further lookups behind stalled DNS work.
  if (_activeOperations >= _maxActiveOperations) {
    return _timedOut;
  }
  _activeOperations++;
  final attempt = _EndpointAttempt(profile);
  return attempt.run().timeout(
    _deadline,
    onTimeout: () {
      attempt.expire();
      return _timedOut;
    },
  );
}

const _timedOut = ProbeResult(reachable: false, errorCode: 'latency_timeout');

final class _EndpointAttempt {
  _EndpointAttempt(this.profile);

  final ConnectionProfile profile;
  bool _expired = false;
  ConnectionTask<Socket>? _connection;

  void expire() {
    _expired = true;
    _connection?.cancel();
  }

  Future<ProbeResult> run() async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      final literal = InternetAddress.tryParse(profile.server);
      final addresses = literal == null
          ? await InternetAddress.lookup(profile.server)
          : [literal];
      // A late DNS completion must never begin a new connection.
      if (_expired) return _timedOut;

      for (final address in addresses) {
        if (_expired) return _timedOut;
        try {
          // Using a resolved address avoids an implicit second DNS lookup.
          final connection = await Socket.startConnect(address, profile.port);
          _connection = connection;
          // startConnect itself may have returned after the deadline. Cancel
          // it and still observe its future so late errors cannot escape.
          if (_expired) connection.cancel();
          socket = await connection.socket;
          if (_expired) return _timedOut;
          return ProbeResult(reachable: true, latency: watch.elapsed);
        } on SocketException {
          if (_expired) return _timedOut;
        } finally {
          socket?.destroy();
          socket = null;
          _connection = null;
        }
      }
      return const ProbeResult(
        reachable: false,
        errorCode: 'latency_unreachable',
      );
    } on SocketException {
      return const ProbeResult(
        reachable: false,
        errorCode: 'latency_unreachable',
      );
    } catch (_) {
      return const ProbeResult(reachable: false, errorCode: 'latency_failed');
    } finally {
      watch.stop();
      socket?.destroy();
      _activeOperations--;
    }
  }
}
