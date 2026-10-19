import 'profile_extensions.dart';
export 'profile_extensions.dart';

enum ProxyProtocol { vless, vmess, trojan, shadowsocks, hysteria2 }

/// Normalized transport. No arbitrary provider configuration is executable.
final class Transport {
  const Transport({
    this.type = 'tcp',
    this.path,
    this.host,
    this.serviceName,
    this.mode,
    this.tcpSudoku,
    this.tcpKeepAliveIdle,
    this.tcpKeepAliveInterval,
    this.wsEarlyDataHeaderName,
  });
  final String type;
  final String? path;
  final String? host;
  final String? serviceName;
  final String? mode;
  final SudokuOptions? tcpSudoku;
  final int? tcpKeepAliveIdle;
  final int? tcpKeepAliveInterval;
  final String? wsEarlyDataHeaderName;

  Map<String, Object?> toJson() => {
    'type': type,
    if (tcpKeepAliveIdle != null) 'tcpKeepAliveIdle': tcpKeepAliveIdle,
    if (tcpKeepAliveInterval != null)
      'tcpKeepAliveInterval': tcpKeepAliveInterval,
    if (wsEarlyDataHeaderName != null)
      'wsEarlyDataHeaderName': wsEarlyDataHeaderName,
    if (path != null) 'path': path,
    if (host != null) 'host': host,
    if (serviceName != null) 'serviceName': serviceName,
    if (mode != null) 'mode': mode,
    if (tcpSudoku != null) 'tcpSudoku': tcpSudoku!.toJson(),
  };
}

final class RealityOptions {
  const RealityOptions({
    required this.publicKey,
    required this.shortId,
    this.spiderX,
  });
  final String publicKey;
  final String shortId;
  final String? spiderX;
  Map<String, Object?> toJson() => {
    'publicKey': publicKey,
    'shortId': shortId,
    if (spiderX != null) 'spiderX': spiderX,
  };
}

final class TlsOptions {
  TlsOptions({
    required this.enabled,
    this.serverName,
    this.fingerprint,
    List<String> alpn = const [],
    this.reality,
  }) : alpn = List.unmodifiable(alpn);
  final bool enabled;
  final String? serverName;
  final String? fingerprint;
  final List<String> alpn;
  final RealityOptions? reality;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    if (serverName != null) 'serverName': serverName,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (alpn.isNotEmpty) 'alpn': alpn,
    if (reality != null) 'reality': reality!.toJson(),
  };
}

/// Contains secrets. Never log/serialize this object except to protected storage
/// or the authenticated native bridge. toString deliberately exposes no fields.
final class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    required this.transport,
    required this.tls,
    this.uuid,
    this.password,
    this.cipher,
    this.flow,
    this.encryption,
    this.packetEncoding,
  });
  final String id;
  final String name;
  final ProxyProtocol protocol;
  final String server;
  final int port;
  final String? uuid;
  final String? password;
  final String? cipher;
  final String? flow;
  final VlessEncryption? encryption;
  final String? packetEncoding;
  final Transport transport;
  final TlsOptions tls;

  Map<String, Object?> toNativeJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'server': server,
    'port': port,
    if (uuid != null) 'uuid': uuid,
    if (password != null) 'password': password,
    if (cipher != null) 'cipher': cipher,
    if (flow != null) 'flow': flow,
    if (packetEncoding != null) 'packetEncoding': packetEncoding,
    if (encryption != null) 'encryption': encryption!.value,
    'transport': transport.toJson(),
    'tls': tls.toJson(),
  };

  @override
  String toString() => 'ConnectionProfile(<redacted>)';
}
