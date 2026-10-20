import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'profile.dart';
part 'additional_protocols.dart';

enum ImportIssueCode {
  empty,
  tooLarge,
  tooManyProfiles,
  unsupportedProtocol,
  unsupportedFeature,
  invalidProfile,
  unsupportedFormat,
  ignoredLocalConfiguration,
}

final class ImportIssue {
  const ImportIssue(
    this.index,
    this.code, {
    this.displayName,
    this.protocolLabel,
  });

  /// One-based line/outbound index; zero denotes the entire document.
  final int index;
  final ImportIssueCode code;

  /// Optional, bounded display metadata. Never an endpoint or an executable
  /// profile; raw records/credentials are discarded even for unsupported nodes.
  final String? displayName;
  final String? protocolLabel;
  bool get isUnsupportedConnection =>
      index > 0 &&
      (code == ImportIssueCode.unsupportedProtocol ||
          code == ImportIssueCode.unsupportedFeature);
  @override
  String toString() => 'ImportIssue($index, $code)';
}

final class ImportResult {
  ImportResult(List<ConnectionProfile> profiles, List<ImportIssue> issues)
    : profiles = List.unmodifiable(profiles),
      issues = List.unmodifiable(issues);
  final List<ConnectionProfile> profiles;
  final List<ImportIssue> issues;
}

final class _Rejected implements Exception {
  const _Rejected(this.code);
  final ImportIssueCode code;
}

/// Bounded pure parser. Never fetches URLs, executes code, or logs input.
final class SubscriptionParser {
  const SubscriptionParser({
    this.maxBytes = 2 * 1024 * 1024,
    this.maxProfiles = 5000,
  });
  final int maxBytes;
  final int maxProfiles;

  ImportResult parse(String input) {
    if (input.length > maxBytes || utf8.encode(input).length > maxBytes) {
      return ImportResult([], [const ImportIssue(0, ImportIssueCode.tooLarge)]);
    }
    var text = input.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) {
      return ImportResult([], [const ImportIssue(0, ImportIssueCode.empty)]);
    }
    try {
      if (text.startsWith('[Interface]')) return _wireguardConfig(text);
      if (!text.contains('://') &&
          !text.startsWith('{') &&
          !text.startsWith('[')) {
        text = _decode64(text.replaceAll(RegExp(r'\s'), '')).trim();
      }
      if (utf8.encode(text).length > maxBytes) {
        throw const _Rejected(ImportIssueCode.tooLarge);
      }
      if (text.startsWith('{') || text.startsWith('[')) return _json(text);
      final lines = const LineSplitter().convert(text);
      if (lines
              .where(
                (line) =>
                    line.trim().isNotEmpty && !line.trim().startsWith('#'),
              )
              .length >
          maxProfiles) {
        throw const _Rejected(ImportIssueCode.tooManyProfiles);
      }
      final nodes = <ConnectionProfile>[];
      final issues = <ImportIssue>[];
      final ids = <String>{};
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        try {
          final profile = _link(line);
          if (ids.add(profile.id)) nodes.add(profile);
        } on _Rejected catch (error) {
          issues.add(_displayIssue(i + 1, error.code, link: line));
        } on FormatException {
          issues.add(ImportIssue(i + 1, ImportIssueCode.invalidProfile));
        } on ArgumentError {
          issues.add(ImportIssue(i + 1, ImportIssueCode.invalidProfile));
        }
      }
      if (nodes.isEmpty && issues.isEmpty) {
        issues.add(const ImportIssue(0, ImportIssueCode.empty));
      }
      return ImportResult(nodes, issues);
    } on _Rejected catch (error) {
      return ImportResult([], [ImportIssue(0, error.code)]);
    } on FormatException {
      return ImportResult([], [
        const ImportIssue(0, ImportIssueCode.unsupportedFormat),
      ]);
    } on ArgumentError {
      return ImportResult([], [
        const ImportIssue(0, ImportIssueCode.unsupportedFormat),
      ]);
    }
  }

  ImportIssue _displayIssue(
    int index,
    ImportIssueCode code, {
    String? link,
    Object? outbound,
  }) {
    if (code != ImportIssueCode.unsupportedProtocol &&
        code != ImportIssueCode.unsupportedFeature) {
      return ImportIssue(index, code);
    }
    String? name;
    Object? protocol;
    Object? transport;
    try {
      if (link != null) {
        final uri = Uri.parse(link);
        protocol = uri.scheme.toLowerCase();
        name = Uri.decodeComponent(uri.fragment);
        transport = uri.queryParameters['type'];
        if (protocol == 'vmess') {
          final node = _map(_decodeJson(_decode64(link.substring(8))));
          name = node['ps'] is String ? node['ps'] as String : null;
          transport = node['net'];
        }
      } else if (outbound is Map<String, dynamic>) {
        name = outbound['tag'] is String ? outbound['tag'] as String : null;
        protocol = outbound['protocol'] ?? outbound['type'];
        final stream = outbound['streamSettings'] ?? outbound['transport'];
        if (stream is Map) transport = stream['network'] ?? stream['type'];
      }
    } catch (_) {
      // Cosmetic metadata cannot change whether a record is accepted.
    }
    const labels = {
      'vless': 'VLESS',
      'vmess': 'VMess',
      'trojan': 'Trojan',
      'ss': 'Shadowsocks',
      'shadowsocks': 'Shadowsocks',
      'ssr': 'ShadowsocksR',
      'hysteria': 'Hysteria',
      'hysteria2': 'Hysteria2',
      'hy2': 'Hysteria2',
      'tuic': 'TUIC',
      'wireguard': 'WireGuard',
      'wg': 'WireGuard',
      'masque': 'MASQUE',
      'socks': 'SOCKS',
      'socks5': 'SOCKS5',
      'http': 'HTTP',
      'https': 'HTTPS',
    };
    final label = protocol is String ? labels[protocol.toLowerCase()] : null;
    const transports = {
      'tcp',
      'ws',
      'grpc',
      'xhttp',
      'h2',
      'http',
      'quic',
      'kcp',
      'httpupgrade',
    };
    final network =
        transport is String && transports.contains(transport.toLowerCase())
        ? transport.toUpperCase()
        : null;
    return ImportIssue(
      index,
      code,
      displayName: _displayName(name),
      protocolLabel: label == null ? null : [label, ?network].join(' · '),
    );
  }

  static String? _displayName(String? value) {
    if (value == null || value.length > 4096) return null;
    final name = value
        .replaceAll(
          RegExp(
            r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty ||
        name.contains(RegExp(r'[<>\\/@]')) ||
        name.contains(
          RegExp(
            r'\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b|\b[a-z0-9_-]{48,}\b',
            caseSensitive: false,
          ),
        )) {
      return null;
    }
    return String.fromCharCodes(name.runes.take(80));
  }

  ConnectionProfile _link(String text) {
    if (text.startsWith('vmess://')) return _vmess(text);
    if (text.startsWith('ss://')) return _shadowsocks(text);
    final uri = Uri.parse(text);
    if ({'wg', 'wireguard'}.contains(uri.scheme.toLowerCase())) {
      return _wireguardLink(uri);
    }
    if ({
      'socks',
      'socks5',
      'http',
      'https',
    }.contains(uri.scheme.toLowerCase())) {
      return _proxyLink(uri);
    }
    final protocol = switch (uri.scheme.toLowerCase()) {
      'vless' => ProxyProtocol.vless,
      'trojan' => ProxyProtocol.trojan,
      'hysteria2' || 'hy2' => ProxyProtocol.hysteria2,
      _ => throw const _Rejected(ImportIssueCode.unsupportedProtocol),
    };
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final q = uri.queryParameters;
    const allowed = {
      'type',
      'security',
      'sni',
      'peer',
      'fp',
      'alpn',
      'pbk',
      'sid',
      'spx',
      'flow',
      'path',
      'host',
      'serviceName',
      'mode',
      'encryption',
      'fm',
    };
    _checkKeys(q, allowed);
    if (protocol != ProxyProtocol.vless &&
        ['flow', 'encryption', 'fm', 'pbk', 'sid', 'spx'].any(q.containsKey)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (uri.queryParametersAll.values.any((values) => values.length > 1)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final security =
        q['security'] ?? (protocol == ProxyProtocol.vless ? 'none' : 'tls');
    if (!{'none', 'tls', 'reality'}.contains(security)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (protocol != ProxyProtocol.vless && security != 'tls') {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final transport = _transport(
      q,
      defaultType: protocol == ProxyProtocol.hysteria2 ? 'hysteria' : 'tcp',
    );
    if (protocol == ProxyProtocol.hysteria2 && transport.type != 'hysteria') {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (protocol != ProxyProtocol.hysteria2 && transport.type == 'hysteria') {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final credentials = Uri.decodeComponent(uri.userInfo);
    if (q['sni'] != null && q['peer'] != null && q['sni'] != q['peer']) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final sni = q['sni'] ?? q['peer'];
    RealityOptions? reality;
    if (security == 'reality') {
      final key = q['pbk'] ?? '';
      final shortId = q['sid'] ?? '';
      if (key.isEmpty ||
          sni == null ||
          sni.isEmpty ||
          !RegExp(r'^[0-9a-fA-F]{0,16}$').hasMatch(shortId) ||
          shortId.length.isOdd) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      reality = RealityOptions(
        publicKey: key,
        shortId: shortId,
        spiderX: q['spx'],
      );
    } else if (['pbk', 'sid', 'spx'].any(q.containsKey)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return _make(
      name: Uri.decodeComponent(uri.fragment),
      protocol: protocol,
      server: uri.host,
      port: uri.hasPort
          ? uri.port
          : (protocol == ProxyProtocol.hysteria2 ? 443 : 0),
      uuid: protocol == ProxyProtocol.vless ? credentials : null,
      password: protocol == ProxyProtocol.vless ? null : credentials,
      flow: q['flow'],
      encryption: _encryption(q['encryption']),
      transport: transport,
      tls: TlsOptions(
        enabled: security != 'none',
        serverName: sni,
        fingerprint: q['fp'],
        alpn: q['alpn']?.split(',') ?? [],
        reality: reality,
      ),
    );
  }

  ConnectionProfile _vmess(String text) {
    final encoded = text.substring('vmess://'.length);
    final j = _map(_decodeJson(_decode64(encoded)));
    _checkKeys(j, {
      'v',
      'ps',
      'add',
      'port',
      'id',
      'aid',
      'scy',
      'net',
      'type',
      'host',
      'path',
      'tls',
      'sni',
      'alpn',
      'fp',
    });
    if ((j['v'] != null && _integer(j['v']) != 2) ||
        _integer(j['aid'] ?? 0) != 0 ||
        (j['type'] != null && j['type'] != '' && j['type'] != 'none')) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final security = _string(j['tls'] ?? '');
    if (!{'', 'none', 'tls'}.contains(security)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final q = <String, String>{
      'type': _string(j['net'] ?? 'tcp'),
      if (j['host'] != null) 'host': _string(j['host']),
      if (j['path'] != null) 'path': _string(j['path']),
    };
    return _make(
      name: _string(j['ps'] ?? ''),
      protocol: ProxyProtocol.vmess,
      server: _string(j['add']),
      port: _integer(j['port']),
      uuid: _string(j['id']),
      cipher: _string(j['scy'] ?? 'auto'),
      transport: _transport(q),
      tls: TlsOptions(
        enabled: security == 'tls',
        serverName: _optional(j['sni']),
        fingerprint: _optional(j['fp']),
        alpn: _optional(j['alpn'])?.split(',') ?? [],
      ),
    );
  }

  ConnectionProfile _shadowsocks(String text) {
    var uri = Uri.parse(text);
    if (uri.queryParameters.isNotEmpty) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    String auth;
    if (uri.userInfo.isEmpty) {
      final data = text.substring(5).split('#').first;
      uri = Uri.parse('ss://${_decode64(data)}');
      if (uri.queryParameters.isNotEmpty || uri.hasFragment) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
      auth = Uri.decodeComponent(uri.userInfo);
    } else {
      auth = Uri.decodeComponent(uri.userInfo);
      if (!auth.contains(':')) auth = _decode64(auth);
    }
    final colon = auth.indexOf(':');
    if (colon < 1) throw const _Rejected(ImportIssueCode.invalidProfile);
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final original = Uri.parse(text);
    return _make(
      name: Uri.decodeComponent(original.fragment),
      protocol: ProxyProtocol.shadowsocks,
      server: uri.host,
      port: uri.hasPort ? uri.port : 0,
      cipher: auth.substring(0, colon),
      password: auth.substring(colon + 1),
      transport: const Transport(),
      tls: TlsOptions(enabled: false),
    );
  }

  ImportResult _json(String text) {
    final root = _decodeJson(text);
    final issues = <ImportIssue>[];
    if (root is! Map<String, dynamic> ||
        (!root.containsKey('outbounds') && !root.containsKey('endpoints')) ||
        (root.containsKey('outbounds') && root['outbounds'] is! List) ||
        (root.containsKey('endpoints') && root['endpoints'] is! List)) {
      throw const _Rejected(ImportIssueCode.unsupportedFormat);
    }
    final outbounds = List<Object?>.from(root['outbounds'] as List? ?? []);
    final endpoints = List<Object?>.from(root['endpoints'] as List? ?? []);
    if (root.keys.any((key) => key != 'outbounds' && key != 'endpoints')) {
      issues.add(
        const ImportIssue(0, ImportIssueCode.ignoredLocalConfiguration),
      );
    }
    if (outbounds.length + endpoints.length > maxProfiles) {
      throw const _Rejected(ImportIssueCode.tooManyProfiles);
    }
    final entries = [...outbounds, ...endpoints];
    final profiles = <ConnectionProfile>[];
    final ids = <String>{};
    for (var i = 0; i < entries.length; i++) {
      try {
        final raw = _map(entries[i]);
        final node = _outbound(
          i >= outbounds.length
              ? _wireguardEndpoint(raw)
              : raw.containsKey('type')
              ? _singBox(raw)
              : raw,
        );
        if (ids.add(node.id)) profiles.add(node);
      } on _Rejected catch (error) {
        issues.add(_displayIssue(i + 1, error.code, outbound: entries[i]));
      } on FormatException {
        issues.add(ImportIssue(i + 1, ImportIssueCode.invalidProfile));
      } on ArgumentError {
        issues.add(ImportIssue(i + 1, ImportIssueCode.invalidProfile));
      }
    }
    if (profiles.isEmpty && issues.isEmpty) {
      issues.add(const ImportIssue(0, ImportIssueCode.empty));
    }
    return ImportResult(profiles, issues);
  }

  /// Translate only explicitly supported remote endpoint fields. Provider
  /// routes, DNS, interfaces and detours never enter the normalized contract.
  Map<String, Object?> _singBox(Map<String, Object?> node) {
    if ({'socks', 'http', 'wireguard'}.contains(node['type'])) {
      return _additionalSingBox(node);
    }
    _checkKeys(node, {
      'type',
      'tag',
      'server',
      'server_port',
      'uuid',
      'password',
      'flow',
      'tls',
      'transport',
      'packet_encoding',
      'security',
      'alter_id',
      'global_padding',
      'authenticated_length',
      'method',
    });
    final type = _string(node['type']);
    if (!{
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'hysteria2',
    }.contains(type)) {
      throw const _Rejected(ImportIssueCode.unsupportedProtocol);
    }
    final usesUuid = type == 'vless' || type == 'vmess';
    if ((usesUuid && node.containsKey('password')) ||
        (!usesUuid && node.containsKey('uuid')) ||
        (type != 'vless' &&
            ['flow', 'packet_encoding'].any(node.containsKey)) ||
        (type != 'shadowsocks' && node.containsKey('method')) ||
        (type != 'vmess' &&
            [
              'security',
              'alter_id',
              'global_padding',
              'authenticated_length',
            ].any(node.containsKey))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    // The existing native contract implements AEAD VMess only. Experimental
    // options with a real wire effect cannot be silently discarded.
    if (type == 'vmess' &&
        ((node.containsKey('alter_id') && node['alter_id'] is! int) ||
            _integer(node['alter_id'] ?? 0) != 0 ||
            (node.containsKey('global_padding') &&
                node['global_padding'] != false) ||
            (node.containsKey('authenticated_length') &&
                node['authenticated_length'] != false))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final tls = node.containsKey('tls')
        ? _map(node['tls'])
        : <String, Object?>{};
    _checkKeys(tls, {
      'enabled',
      'server_name',
      'utls',
      'reality',
      'alpn',
      'insecure',
    });
    final enabled = tls['enabled'] ?? false;
    if (enabled is! bool ||
        (tls['insecure'] != null && tls['insecure'] != false)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final utls = tls.containsKey('utls')
        ? _map(tls['utls'])
        : <String, Object?>{};
    _checkKeys(utls, {'enabled', 'fingerprint'});
    if (utls.isNotEmpty && utls['enabled'] != true) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final reality = tls.containsKey('reality')
        ? _map(tls['reality'])
        : <String, Object?>{};
    _checkKeys(reality, {'enabled', 'public_key', 'short_id'});
    if (reality.isNotEmpty && (reality['enabled'] != true || !enabled)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (type != 'vless' && reality.isNotEmpty) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (!enabled && tls.keys.any((key) => key != 'enabled')) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final security = !enabled
        ? 'none'
        : reality.isEmpty
        ? 'tls'
        : 'reality';
    final tlsData = <String, Object?>{
      if (tls.containsKey('server_name')) 'serverName': tls['server_name'],
      if (utls.containsKey('fingerprint')) 'fingerprint': utls['fingerprint'],
      if (tls.containsKey('alpn'))
        'alpn': tls['alpn'] is String ? [tls['alpn']] : tls['alpn'],
      if (reality.isNotEmpty) 'publicKey': reality['public_key'],
      if (reality.isNotEmpty) 'shortId': reality['short_id'] ?? '',
    };
    final stream = <String, Object?>{
      'security': security,
      if (enabled) '${security}Settings': tlsData,
    };
    if (node.containsKey('transport')) {
      final transport = _map(node['transport']);
      _checkKeys(transport, {
        'type',
        'path',
        'host',
        'mode',
        'headers',
        'early_data_header_name',
        'service_name',
      });
      final network = _string(transport['type']);
      if (!{'ws', 'xhttp', 'grpc'}.contains(network) || type == 'hysteria2') {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
      stream['network'] = network;
      stream['${network}Settings'] = <String, Object?>{
        for (final key in ['path', 'host', 'mode', 'headers'])
          if (transport.containsKey(key)) key: transport[key],
        if (transport.containsKey('early_data_header_name'))
          'earlyDataHeaderName': transport['early_data_header_name'],
        if (transport.containsKey('service_name'))
          'serviceName': transport['service_name'],
      };
    }
    if (type == 'hysteria2') {
      stream['network'] = 'hysteria';
      stream['hysteriaSettings'] = {'version': 2, 'auth': node['password']};
    }
    final server = <String, Object?>{
      'address': node['server'],
      'port': node['server_port'],
    };
    if (usesUuid) {
      server['users'] = [
        {
          'id': node['uuid'],
          if (type == 'vless') 'encryption': 'none',
          if (node.containsKey('flow')) 'flow': node['flow'],
          if (type == 'vmess') 'security': node['security'] ?? 'auto',
          if (type == 'vmess') 'alterId': 0,
        },
      ];
    } else if (type != 'hysteria2') {
      server['password'] = node['password'];
      if (type == 'shadowsocks') server['method'] = node['method'];
    }
    return {
      'protocol': type == 'hysteria2' ? 'hysteria' : type,
      if (node.containsKey('tag')) 'tag': node['tag'],
      if (node.containsKey('packet_encoding'))
        'packetEncoding': node['packet_encoding'],
      'settings': type == 'hysteria2'
          ? {
              'version': 2,
              'address': node['server'],
              'port': node['server_port'],
            }
          : {
              usesUuid ? 'vnext' : 'servers': [server],
            },
      'streamSettings': stream,
    };
  }

  ConnectionProfile _outbound(Map<String, Object?> node) {
    if ({'socks', 'http', 'wireguard', 'masque'}.contains(node['protocol'])) {
      return _additionalOutbound(node);
    }
    _checkKeys(node, {
      'tag',
      'protocol',
      'settings',
      'streamSettings',
      'packetEncoding',
    });
    final protocol = switch (node['protocol']) {
      'vless' => ProxyProtocol.vless,
      'vmess' => ProxyProtocol.vmess,
      'trojan' => ProxyProtocol.trojan,
      'shadowsocks' => ProxyProtocol.shadowsocks,
      'hysteria' => ProxyProtocol.hysteria2,
      _ => throw const _Rejected(ImportIssueCode.unsupportedProtocol),
    };
    final settings = _map(node['settings']);
    final isVmess = protocol == ProxyProtocol.vmess;
    final isHysteria = protocol == ProxyProtocol.hysteria2;
    final isUser = protocol == ProxyProtocol.vless || isVmess;
    final listKey = isUser ? 'vnext' : 'servers';
    _checkKeys(
      settings,
      isHysteria ? {'version', 'address', 'port'} : {listKey},
    );
    if (isHysteria && _integer(settings['version']) != 2) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final servers = isHysteria ? [settings] : settings[listKey];
    if (servers is! List || servers.length != 1) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final server = _map(servers.single);
    _checkKeys(
      server,
      isUser
          ? {'address', 'port', 'users'}
          : isHysteria
          ? {'version', 'address', 'port'}
          : protocol == ProxyProtocol.shadowsocks
          ? {'address', 'port', 'password', 'method', 'level', 'email'}
          : {'address', 'port', 'password', 'level', 'email'},
    );
    Map<String, Object?> user = server;
    if (isUser) {
      final users = server['users'];
      if (users is! List || users.length != 1) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
      user = _map(users.single);
      _checkKeys(
        user,
        isVmess
            ? {'id', 'security', 'alterId', 'level', 'email'}
            : {'id', 'encryption', 'flow', 'level', 'email'},
      );
      if (_integer(user['alterId'] ?? 0) != 0) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
    }
    final stream = node['streamSettings'] == null
        ? <String, Object?>{}
        : _map(node['streamSettings']);
    _checkKeys(stream, {
      'network',
      'security',
      'tlsSettings',
      'realitySettings',
      'wsSettings',
      'grpcSettings',
      'xhttpSettings',
      'hysteriaSettings',
      'finalmask',
      'sockopt',
      'tcpSettings',
      'rawSettings',
    });
    final socket = stream.containsKey('sockopt')
        ? _map(stream['sockopt'])
        : <String, Object?>{};
    _checkKeys(socket, {'tcpKeepAliveIdle', 'tcpKeepAliveInterval'});
    if (isHysteria && socket.isNotEmpty) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    for (final value in socket.values) {
      if (value is! int || value < 1 || value > 86400) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
    }
    if (stream.containsKey('tcpSettings') &&
        stream.containsKey('rawSettings')) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (stream.containsKey('tcpSettings') ||
        stream.containsKey('rawSettings')) {
      final tcp = _map(
        stream[stream.containsKey('rawSettings')
            ? 'rawSettings'
            : 'tcpSettings'],
      );
      _checkKeys(tcp, {'header', 'acceptProxyProtocol'});
      if (tcp.containsKey('acceptProxyProtocol') &&
          tcp['acceptProxyProtocol'] != false) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
      if (tcp.containsKey('header')) {
        final header = _map(tcp['header']);
        _checkKeys(header, {'type'});
        if (header['type'] != 'none') {
          throw const _Rejected(ImportIssueCode.unsupportedFeature);
        }
      }
      if (!{'tcp', 'raw'}.contains(stream['network'] ?? 'tcp')) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
    }
    final security = _string(stream['security'] ?? 'none');
    if (!{'none', 'tls', 'reality'}.contains(security)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    for (final key in ['tlsSettings', 'realitySettings']) {
      if (stream.containsKey(key) && key != '${security}Settings') {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
    }
    final tls = security == 'none'
        ? <String, Object?>{}
        : _map(
            stream[security == 'tls' ? 'tlsSettings' : 'realitySettings'] ??
                <String, Object?>{},
          );
    _checkKeys(
      tls,
      security == 'reality'
          ? {
              'serverName',
              'fingerprint',
              'publicKey',
              'password',
              'shortId',
              'spiderX',
              'show',
            }
          : {'serverName', 'fingerprint', 'alpn', 'allowInsecure'},
    );
    if (tls['show'] != null && tls['show'] != false) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (tls['allowInsecure'] != null && tls['allowInsecure'] != false) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    // The pinned Xray calls this REALITY public key "password" in newer
    // exports. Both names refer to the same peer key; conflicts are rejected.
    if (security == 'reality' && tls.containsKey('password')) {
      final key = _string(tls['password']);
      if (tls.containsKey('publicKey') && tls['publicKey'] != key) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      tls['publicKey'] = key;
      tls.remove('password');
    }
    final type = _string(
      stream['network'] ?? (isHysteria ? 'hysteria' : 'tcp'),
    );
    final transportData = <String, String>{'type': type};
    if (stream.containsKey('finalmask')) {
      transportData['fm'] = jsonEncode(stream['finalmask']);
    }
    final subKey = switch (type) {
      'ws' => 'wsSettings',
      'grpc' => 'grpcSettings',
      'xhttp' => 'xhttpSettings',
      _ => null,
    };
    for (final key in ['wsSettings', 'grpcSettings', 'xhttpSettings']) {
      if (stream.containsKey(key) && key != subKey) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
    }
    String? hysteriaAuth;
    if (isHysteria) {
      final hysteria = _map(stream['hysteriaSettings']);
      _checkKeys(hysteria, {'version', 'auth'});
      if (_integer(hysteria['version'] ?? 2) != 2 || security != 'tls') {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      hysteriaAuth = _string(hysteria['auth']);
    } else if (stream.containsKey('hysteriaSettings')) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (subKey != null && stream[subKey] != null) {
      final sub = _map(stream[subKey]);
      _checkKeys(sub, switch (type) {
        'ws' => {'path', 'host', 'headers', 'earlyDataHeaderName'},
        'grpc' => {'serviceName'},
        'xhttp' => {'path', 'host', 'mode'},
        _ => <String>{},
      });
      for (final key in [
        'path',
        'host',
        'serviceName',
        'mode',
        'earlyDataHeaderName',
      ]) {
        if (sub[key] != null) transportData[key] = _string(sub[key]);
      }
      if (sub['headers'] != null) {
        final headers = _map(sub['headers']);
        _checkKeys(headers, {'Host'});
        if (headers['Host'] != null &&
            sub['host'] != null &&
            headers['Host'] != sub['host']) {
          throw const _Rejected(ImportIssueCode.invalidProfile);
        }
        if (headers['Host'] != null) {
          transportData['host'] = _string(headers['Host']);
        }
      }
    }
    final alpn = tls['alpn'];
    if (alpn != null &&
        (alpn is! List || alpn.any((entry) => entry is! String))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (protocol == ProxyProtocol.trojan && security != 'tls') {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return _make(
      name: _string(node['tag'] ?? ''),
      protocol: protocol,
      server: _string(server['address']),
      port: _integer(server['port']),
      uuid: isUser ? _string(user['id']) : null,
      password: isUser
          ? null
          : isHysteria
          ? hysteriaAuth
          : _string(server['password']),
      cipher: isVmess
          ? _string(user['security'] ?? 'auto')
          : _optional(server['method']),
      flow: _optional(user['flow']),
      encryption: _encryption(_optional(user['encryption'])),
      transport: _transport(transportData, socket: socket),
      packetEncoding: _optional(node['packetEncoding']),
      tls: TlsOptions(
        enabled: security != 'none',
        serverName: _optional(tls['serverName']),
        fingerprint: _optional(tls['fingerprint']),
        alpn: alpn == null ? [] : (alpn as List).cast<String>(),
        reality: security == 'reality'
            ? RealityOptions(
                publicKey: _string(tls['publicKey']),
                shortId: _string(tls['shortId'] ?? ''),
                spiderX: _optional(tls['spiderX']),
              )
            : null,
      ),
    );
  }

  Transport _transport(
    Map<String, String> q, {
    String defaultType = 'tcp',
    Map<String, Object?> socket = const {},
  }) {
    var type = q['type'] ?? defaultType;
    if (type == 'raw') type = 'tcp';
    if (!{'tcp', 'ws', 'grpc', 'xhttp', 'hysteria'}.contains(type)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final path = _nonEmpty(q['path']);
    final host = _nonEmpty(q['host']);
    final service = _nonEmpty(q['serviceName']);
    // Share links call the default gRPC transport "gun". Canonicalize that
    // explicit default; other gRPC modes still require a separate adapter.
    final requestedMode = _nonEmpty(q['mode']);
    final mode = type == 'grpc' && requestedMode == 'gun'
        ? null
        : requestedMode;
    if (((path != null || host != null) && !{'ws', 'xhttp'}.contains(type)) ||
        (service != null && type != 'grpc') ||
        (mode != null &&
            (type != 'xhttp' ||
                !{
                  'auto',
                  'packet-up',
                  'stream-up',
                  'stream-one',
                }.contains(mode)))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if ((path != null && (!path.startsWith('/') || !_clean(path, 4096))) ||
        (host != null && !_validHost(host)) ||
        (service != null && !_clean(service, 256))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return Transport(
      type: type,
      path: path,
      host: host,
      serviceName: service,
      mode: mode,
      tcpSudoku: q.containsKey('fm') ? _sudoku(q['fm']!) : null,
      tcpKeepAliveIdle: socket['tcpKeepAliveIdle'] as int?,
      tcpKeepAliveInterval: socket['tcpKeepAliveInterval'] as int?,
      wsEarlyDataHeaderName: q['earlyDataHeaderName'],
    );
  }

  static VlessEncryption? _encryption(String? value) =>
      value == null || value == 'none' ? null : VlessEncryption.parse(value);

  static SudokuOptions _sudoku(String text) {
    if (utf8.encode(text).length > 16384) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final mask = _map(_decodeJson(text));
    _checkKeys(mask, {'tcp'});
    final tcp = mask['tcp'];
    if (tcp is! List || tcp.length != 1) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final entry = _map(tcp.single);
    _checkKeys(entry, {'type', 'settings'});
    if (entry['type'] != 'sudoku') {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    return SudokuOptions.fromJson(_map(entry['settings']));
  }

  ConnectionProfile _make({
    required String name,
    required ProxyProtocol protocol,
    required String server,
    required int port,
    required Transport transport,
    required TlsOptions tls,
    String? uuid,
    String? password,
    String? cipher,
    String? flow,
    VlessEncryption? encryption,
    String? packetEncoding,
    String? username,
    WireGuardOptions? wireguard,
  }) {
    _validateAdditional(
      protocol,
      transport,
      tls,
      username,
      password,
      wireguard,
    );
    if ((packetEncoding != null &&
            (packetEncoding != 'xudp' || protocol != ProxyProtocol.vless)) ||
        (transport.wsEarlyDataHeaderName != null &&
            (transport.type != 'ws' ||
                transport.wsEarlyDataHeaderName != 'Sec-WebSocket-Protocol'))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (server.startsWith('[') && server.endsWith(']')) {
      server = server.substring(1, server.length - 1);
    }
    if ({'0.0.0.0', '::', '::0'}.contains(server) ||
        !_validHost(server) ||
        port < 1 ||
        port > 65535 ||
        (password != null && (password.isEmpty || !_clean(password, 4096)))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (uuid != null &&
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(uuid)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    flow = _nonEmpty(flow);
    if (flow != null &&
        (protocol != ProxyProtocol.vless ||
            flow != 'xtls-rprx-vision' ||
            transport.type != 'tcp' ||
            (!tls.enabled && encryption == null))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if ((encryption != null && protocol != ProxyProtocol.vless) ||
        (transport.tcpSudoku != null &&
            (protocol != ProxyProtocol.vless ||
                transport.type != 'tcp' ||
                (!tls.enabled && encryption == null)))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (protocol == ProxyProtocol.shadowsocks &&
        cipher == 'chacha20-poly1305') {
      cipher = 'chacha20-ietf-poly1305';
    }
    if (protocol == ProxyProtocol.shadowsocks &&
        !{
          'aes-128-gcm',
          'aes-256-gcm',
          'chacha20-poly1305',
          'chacha20-ietf-poly1305',
          '2022-blake3-aes-128-gcm',
          '2022-blake3-aes-256-gcm',
          '2022-blake3-chacha20-poly1305',
        }.contains(cipher)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (protocol == ProxyProtocol.vmess &&
        !{'auto', 'aes-128-gcm', 'chacha20-poly1305'}.contains(cipher)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if ((protocol == ProxyProtocol.hysteria2) !=
            (transport.type == 'hysteria') ||
        (!tls.enabled &&
            (tls.serverName?.isNotEmpty == true ||
                tls.fingerprint?.isNotEmpty == true ||
                tls.alpn.isNotEmpty ||
                tls.reality != null)) ||
        (tls.serverName?.isNotEmpty == true && !_validHost(tls.serverName!))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (!{
      null,
      '',
      'chrome',
      'firefox',
      'safari',
      'ios',
      'android',
      'edge',
      'qq',
      'random',
      'randomized',
    }.contains(tls.fingerprint)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    if (tls.alpn.length > 8 ||
        tls.alpn.any((value) => value.isEmpty || !_clean(value, 255))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final reality = tls.reality;
    if (reality != null) {
      if (protocol != ProxyProtocol.vless ||
          !{'tcp', 'xhttp', 'grpc'}.contains(transport.type) ||
          tls.serverName == null ||
          tls.serverName!.isEmpty ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(reality.publicKey) ||
          base64Url.decode(base64Url.normalize(reality.publicKey)).length !=
              32 ||
          !RegExp(r'^(?:[0-9a-fA-F]{2}){0,8}$').hasMatch(reality.shortId) ||
          (reality.spiderX?.isNotEmpty == true &&
              (!reality.spiderX!.startsWith('/') ||
                  !_clean(reality.spiderX!, 1024))) ||
          tls.alpn.isNotEmpty) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
    }
    final cleanName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    var displayName = cleanName.isEmpty
        ? protocol.name.toUpperCase()
        : String.fromCharCodes(cleanName.runes.take(100));
    while (utf8.encode(displayName).length > 256) {
      displayName = String.fromCharCodes(
        displayName.runes.take(displayName.runes.length - 1),
      );
    }
    final content = {
      'protocol': protocol.name,
      'server': server.toLowerCase(),
      'port': port,
      'uuid': uuid?.toLowerCase(),
      'password': password,
      'username': ?username,
      if (wireguard != null) 'wireguard': wireguard.toJson(),
      'cipher': cipher,
      'flow': flow,
      'packetEncoding': ?packetEncoding,
      if (encryption != null) 'encryption': encryption.value,
      'transport': transport.toJson(),
      'tls': tls.toJson(),
    };
    return ConnectionProfile(
      id: sha256.convert(utf8.encode(jsonEncode(content))).toString(),
      name: displayName,
      protocol: protocol,
      server: server,
      port: port,
      uuid: uuid,
      password: password,
      username: username,
      wireguard: wireguard,
      cipher: cipher,
      flow: flow,
      packetEncoding: packetEncoding,
      encryption: encryption,
      transport: transport,
      tls: tls,
    );
  }

  static void _checkKeys(Map<String, Object?> map, Set<String> allowed) {
    if (map.keys.any((key) => !allowed.contains(key))) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (value.values.any((entry) => entry == null)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return Map<String, Object?>.from(value);
  }

  static String _string(Object? value) {
    if (value is! String) throw const _Rejected(ImportIssueCode.invalidProfile);
    return value;
  }

  static String? _optional(Object? value) =>
      value == null ? null : _string(value);
  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
  static bool _clean(String value, int max) =>
      utf8.encode(value).length <= max &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));
  static bool _validHost(String value) {
    if (value.isEmpty || value.length > 253) return false;
    if (value.contains(':')) {
      if (value.contains(RegExp(r'[^0-9a-fA-F:.]'))) return false;
      return Uri.tryParse('http://[$value]') != null;
    }
    return RegExp(
      r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?$',
    ).hasMatch(value);
  }

  /// Bound nesting and reject ambiguous duplicate object keys before decoding.
  static Object? _decodeJson(String text) {
    final frames = <({bool object, Set<String> keys, bool expectsKey})>[];
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        final start = i;
        var closed = false;
        for (i++; i < text.length; i++) {
          if (text[i] == r'\') {
            i++;
          } else if (text[i] == '"') {
            closed = true;
            break;
          }
        }
        if (!closed) throw const _Rejected(ImportIssueCode.invalidProfile);
        if (frames.isNotEmpty && frames.last.object && frames.last.expectsKey) {
          final frame = frames.removeLast();
          final key = jsonDecode(text.substring(start, i + 1)) as String;
          if (!frame.keys.add(key)) {
            throw const _Rejected(ImportIssueCode.invalidProfile);
          }
          frames.add((object: true, keys: frame.keys, expectsKey: false));
        }
      } else if (char == '{' || char == '[') {
        if (frames.length >= 64) {
          throw const _Rejected(ImportIssueCode.invalidProfile);
        }
        frames.add((
          object: char == '{',
          keys: <String>{},
          expectsKey: char == '{',
        ));
      } else if (char == '}' || char == ']') {
        if (frames.isNotEmpty) frames.removeLast();
      } else if (char == ',' && frames.isNotEmpty && frames.last.object) {
        final frame = frames.removeLast();
        frames.add((object: true, keys: frame.keys, expectsKey: true));
      }
    }
    return jsonDecode(text);
  }

  static int _integer(Object? value) {
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw const _Rejected(ImportIssueCode.invalidProfile);
  }

  static String _decode64(String value) =>
      utf8.decode(base64.decode(base64.normalize(value)));
}
