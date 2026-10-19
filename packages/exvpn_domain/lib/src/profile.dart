import 'dart:convert';
import 'profile_extensions.dart';
export 'profile_extensions.dart';

enum ProxyProtocol {
  vless,
  vmess,
  trojan,
  shadowsocks,
  hysteria2,
  socks5,
  http,
  wireguard,
}

/// One remote WireGuard peer. Never contains OS routes, DNS or hooks.
final class WireGuardOptions {
  WireGuardOptions({
    required this.privateKey,
    required this.publicKey,
    required List<String> addresses,
    this.preSharedKey,
    this.mtu = 1420,
    this.keepAlive = 0,
    List<int> reserved = const [],
  }) : addresses = List.unmodifiable(addresses),
       reserved = List.unmodifiable(reserved) {
    if (!isValid) throw const FormatException('Invalid WireGuard options');
  }
  final String privateKey;
  final String publicKey;
  final String? preSharedKey;
  final List<String> addresses;
  final int mtu;
  final int keepAlive;
  final List<int> reserved;
  bool get isValid {
    bool key(String value) {
      try {
        final b = base64.decode(value);
        return b.length == 32 && b.any((x) => x != 0);
      } on FormatException {
        return false;
      }
    }

    return key(privateKey) &&
        key(publicKey) &&
        (preSharedKey == null || key(preSharedKey!)) &&
        addresses.isNotEmpty &&
        addresses.length <= 2 &&
        addresses.toSet().length == addresses.length &&
        addresses.every(_validTunnelCIDR) &&
        mtu >= 1280 &&
        mtu <= 1420 &&
        keepAlive >= 0 &&
        keepAlive <= 120 &&
        (reserved.isEmpty || reserved.length == 3) &&
        reserved.every((x) => x >= 0 && x <= 255);
  }

  Map<String, Object?> toJson() => {
    'privateKey': privateKey,
    'publicKey': publicKey,
    if (preSharedKey != null) 'preSharedKey': preSharedKey,
    'addresses': addresses,
    'mtu': mtu,
    if (keepAlive != 0) 'keepAlive': keepAlive,
    if (reserved.isNotEmpty) 'reserved': reserved,
  };
  @override
  String toString() => 'WireGuardOptions(<redacted>)';
}

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
    this.username,
    this.wireguard,
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
  final String? username;
  final WireGuardOptions? wireguard;
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
    if (username != null) 'username': username,
    if (wireguard != null) 'wireguard': wireguard!.toJson(),
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

bool _validTunnelCIDR(String value) {
  final pieces = value.split('/');
  if (pieces.length != 2) return false;
  final prefix = int.tryParse(pieces[1]);
  if (prefix == null || prefix < 1) return false;
  final ip = pieces[0];
  if (ip.contains(':')) {
    if (prefix > 128 ||
        !RegExp(r'^[0-9a-fA-F:]+$').hasMatch(ip) ||
        ip.split('::').length > 2) {
      return false;
    }
    final groups = ip.split(':').where((x) => x.isNotEmpty).toList();
    return groups.every((x) => x.length <= 4) &&
        !(groups.isNotEmpty && groups.first.toLowerCase().startsWith('ff')) &&
        (ip.contains('::') ? groups.length < 8 : groups.length == 8) &&
        groups.any((x) => int.parse(x, radix: 16) != 0);
  }
  final octets = ip.split('.');
  return prefix <= 32 &&
      octets.length == 4 &&
      octets.every(
        (x) => RegExp(r'^\d{1,3}$').hasMatch(x) && int.parse(x) <= 255,
      ) &&
      octets.any((x) => int.parse(x) != 0) &&
      (int.parse(octets.first) < 224 || int.parse(octets.first) > 239);
}
