import 'package:exvpn_domain/exvpn_domain.dart';

/// Browsers cannot open arbitrary TCP connections. Previews inject a simulator.
Future<ProbeResult> probeServerLatency(ConnectionProfile profile) async =>
    const ProbeResult(
      reachable: false,
      errorCode: 'latency_platform_unsupported',
    );
