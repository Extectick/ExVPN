part of 'subscription_parser.dart';

extension _AdditionalProtocols on SubscriptionParser {
  // v2rayNG/v2rayN share format. Secrets are decoded once, never logged.
  ConnectionProfile _wireguardLink(Uri uri) {
    if (!uri.hasPort ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.userInfo.isEmpty ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final q = uri.queryParameters;
    SubscriptionParser._checkKeys(q, {
      'publickey',
      'presharedkey',
      'address',
      'mtu',
      'keepalive',
      'reserved',
    });
    int number(String key, int fallback) {
      if (!q.containsKey(key)) return fallback;
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(q[key]!)) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      return int.parse(q[key]!);
    }

    return _make(
      name: Uri.decodeComponent(uri.fragment),
      protocol: ProxyProtocol.wireguard,
      server: uri.host,
      port: uri.port,
      transport: const Transport(),
      tls: TlsOptions(enabled: false),
      wireguard: WireGuardOptions(
        privateKey: Uri.decodeComponent(uri.userInfo),
        publicKey: SubscriptionParser._string(q['publickey']),
        preSharedKey: SubscriptionParser._optional(q['presharedkey']),
        addresses: SubscriptionParser._string(
          q['address'],
        ).split(',').map((value) => value.trim()).toList(),
        mtu: number('mtu', 1420),
        keepAlive: number('keepalive', 0),
        reserved: q.containsKey('reserved')
            ? _wireguardReserved(q['reserved'])
            : [],
      ),
    );
  }

  // Current sing-box endpoints are distinct from legacy outbounds. Only a
  // remote one-peer userspace profile is translated; no interface is created.
  Map<String, Object?> _wireguardEndpoint(Map<String, Object?> node) {
    if (node['type'] != 'wireguard') {
      throw const _Rejected(ImportIssueCode.unsupportedProtocol);
    }
    SubscriptionParser._checkKeys(node, {
      'type',
      'tag',
      'system',
      'name',
      'mtu',
      'address',
      'private_key',
      'listen_port',
      'peers',
      'workers',
      'on_demand',
    });
    if ((node.containsKey('system') && node['system'] != false) ||
        (node.containsKey('name') && node['name'] != '') ||
        (node.containsKey('listen_port') &&
            (node['listen_port'] is! int || node['listen_port'] != 0)) ||
        (node.containsKey('workers') &&
            (node['workers'] is! int || node['workers'] != 0)) ||
        (node.containsKey('on_demand') && node['on_demand'] != false)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final rawPeers = node['peers'];
    final peers = rawPeers is Map ? [rawPeers] : rawPeers;
    if (peers is! List || peers.length != 1) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final peer = SubscriptionParser._map(peers.single);
    SubscriptionParser._checkKeys(peer, {
      'address',
      'port',
      'public_key',
      'pre_shared_key',
      'allowed_ips',
      'persistent_keepalive_interval',
      'reserved',
    });
    if (!peer.containsKey('allowed_ips')) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    if (peer['port'] is! int ||
        (node.containsKey('mtu') && node['mtu'] is! int) ||
        (peer.containsKey('persistent_keepalive_interval') &&
            peer['persistent_keepalive_interval'] is! int)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final addresses = node['address'];
    return {
      if (node.containsKey('tag')) 'tag': node['tag'],
      'protocol': 'wireguard',
      'settings': {
        'secretKey': node['private_key'],
        'address': addresses is String ? [addresses] : addresses,
        'mtu': node['mtu'] ?? 1408,
        if (peer.containsKey('reserved'))
          'reserved': _wireguardReserved(peer['reserved']),
        'peers': [
          {
            'endpoint': _endpoint(
              SubscriptionParser._string(peer['address']),
              SubscriptionParser._integer(peer['port']),
            ),
            'publicKey': peer['public_key'],
            if (peer.containsKey('pre_shared_key'))
              'preSharedKey': peer['pre_shared_key'],
            'allowedIPs': peer['allowed_ips'],
            if (peer.containsKey('persistent_keepalive_interval'))
              'keepAlive': peer['persistent_keepalive_interval'],
          },
        ],
      },
    };
  }

  List<int> _wireguardReserved(Object? value) {
    if (value is List && value.every((item) => item is int)) {
      return value.cast<int>();
    }
    if (value is String) {
      if (RegExp(r'^[0-9]+,[0-9]+,[0-9]+$').hasMatch(value)) {
        return value.split(',').map(int.parse).toList();
      }
      // The base64 form is used by clients serializing three reserved bytes.
      final decoded = base64.decode(value);
      if (decoded.length == 3 && base64.encode(decoded) == value) {
        return decoded;
      }
    }
    throw const _Rejected(ImportIssueCode.invalidProfile);
  }

  ImportResult _wireguardConfig(String text) {
    var section = '';
    final interface = <String, String>{};
    final peer = <String, String>{};
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      if (line == '[Interface]' || line == '[Peer]') {
        if ((line == '[Interface]' && section.isNotEmpty) ||
            (line == '[Peer]' && section != '[Interface]')) {
          throw const _Rejected(ImportIssueCode.unsupportedFeature);
        }
        section = line;
        continue;
      }
      final equal = line.indexOf('=');
      if (equal < 1 || section.isEmpty) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      final key = line.substring(0, equal).trim();
      final value = line.substring(equal + 1).trim();
      final target = section == '[Interface]' ? interface : peer;
      if (target.containsKey(key) || value.isEmpty) {
        throw const _Rejected(ImportIssueCode.invalidProfile);
      }
      target[key] = value;
    }
    SubscriptionParser._checkKeys(interface, {
      'PrivateKey',
      'Address',
      'MTU',
      'DNS',
    });
    SubscriptionParser._checkKeys(peer, {
      'PublicKey',
      'PresharedKey',
      'Endpoint',
      'AllowedIPs',
      'PersistentKeepalive',
    });
    // External OS hooks, routing tables and multiple peers are unsupported.
    // DNS is explicitly ignored like JSON root DNS, never assigned to the OS.
    final outbound = <String, Object?>{
      'protocol': 'wireguard',
      'settings': {
        'secretKey': interface['PrivateKey'],
        'address': interface['Address']
            ?.split(',')
            .map((x) => x.trim())
            .toList(),
        if (interface.containsKey('MTU'))
          'mtu': int.tryParse(interface['MTU']!),
        'peers': [
          {
            'publicKey': peer['PublicKey'],
            'endpoint': peer['Endpoint'],
            if (peer.containsKey('PresharedKey'))
              'preSharedKey': peer['PresharedKey'],
            if (peer.containsKey('AllowedIPs'))
              'allowedIPs': peer['AllowedIPs']!
                  .split(',')
                  .map((x) => x.trim())
                  .toList(),
            if (peer.containsKey('PersistentKeepalive'))
              'keepAlive': int.tryParse(peer['PersistentKeepalive']!),
          },
        ],
      },
    };
    final p = _wireguardOutbound(outbound);
    return ImportResult(
      [p],
      [
        if (interface.containsKey('DNS'))
          const ImportIssue(0, ImportIssueCode.ignoredLocalConfiguration),
      ],
    );
  }

  ConnectionProfile _proxyLink(Uri uri) {
    if ((uri.path.isNotEmpty && uri.path != '/') || uri.query.isNotEmpty) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final auth = uri.userInfo;
    String? username, password;
    if (auth.isNotEmpty) {
      final colon = auth.indexOf(':');
      if (colon <= 0) throw const _Rejected(ImportIssueCode.invalidProfile);
      username = Uri.decodeComponent(auth.substring(0, colon));
      password = Uri.decodeComponent(auth.substring(colon + 1));
    }
    final encrypted = uri.scheme == 'https';
    return _make(
      name: Uri.decodeComponent(uri.fragment),
      protocol: {'socks', 'socks5'}.contains(uri.scheme)
          ? ProxyProtocol.socks5
          : ProxyProtocol.http,
      server: uri.host,
      port: uri.hasPort
          ? uri.port
          : encrypted
          ? 443
          : uri.scheme == 'http'
          ? 80
          : 1080,
      username: username,
      password: password,
      transport: const Transport(),
      tls: TlsOptions(
        enabled: encrypted,
        serverName: encrypted ? uri.host : null,
      ),
    );
  }

  ConnectionProfile _additionalOutbound(Map<String, Object?> node) {
    SubscriptionParser._checkKeys(node, {
      'tag',
      'protocol',
      'settings',
      'streamSettings',
    });
    if (node['protocol'] == 'wireguard') return _wireguardOutbound(node);
    if (node['protocol'] == 'masque') return _masqueOutbound(node);
    final settings = SubscriptionParser._map(node['settings']);
    SubscriptionParser._checkKeys(settings, {'servers'});
    final servers = settings['servers'];
    if (servers is! List || servers.length != 1) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final server = SubscriptionParser._map(servers.single);
    SubscriptionParser._checkKeys(server, {'address', 'port', 'users'});
    String? username, password;
    if (server.containsKey('users')) {
      final users = server['users'];
      if (users is! List || users.length > 1) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
      if (users.isNotEmpty) {
        final user = SubscriptionParser._map(users.single);
        SubscriptionParser._checkKeys(user, {'user', 'pass', 'level', 'email'});
        username = SubscriptionParser._string(user['user']);
        password = SubscriptionParser._string(user['pass']);
      }
    }
    final stream = node.containsKey('streamSettings')
        ? SubscriptionParser._map(node['streamSettings'])
        : <String, Object?>{};
    SubscriptionParser._checkKeys(stream, {
      'network',
      'security',
      'tlsSettings',
    });
    if ((stream['network'] ?? 'tcp') != 'tcp') {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final security = stream['security'] ?? 'none';
    if (!{'none', 'tls'}.contains(security)) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final tls = stream.containsKey('tlsSettings')
        ? SubscriptionParser._map(stream['tlsSettings'])
        : <String, Object?>{};
    SubscriptionParser._checkKeys(tls, {
      'serverName',
      'fingerprint',
      'alpn',
      'allowInsecure',
    });
    if ((tls['allowInsecure'] != null && tls['allowInsecure'] != false) ||
        (security != 'tls' && tls.isNotEmpty)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final alpn = tls['alpn'];
    if (alpn != null && (alpn is! List || alpn.any((x) => x is! String))) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return _make(
      name: SubscriptionParser._string(node['tag'] ?? ''),
      protocol: node['protocol'] == 'socks'
          ? ProxyProtocol.socks5
          : ProxyProtocol.http,
      server: SubscriptionParser._string(server['address']),
      port: SubscriptionParser._integer(server['port']),
      username: username,
      password: password,
      transport: const Transport(),
      tls: TlsOptions(
        enabled: security == 'tls',
        serverName: SubscriptionParser._optional(tls['serverName']),
        fingerprint: SubscriptionParser._optional(tls['fingerprint']),
        alpn: alpn == null ? [] : (alpn as List).cast<String>(),
      ),
    );
  }

  /// Only the pinned Xray MASQUE CONNECT-IP default transport is projected.
  /// Provider DNS, custom paths/headers and local QUIC listeners are not policy.
  ConnectionProfile _masqueOutbound(Map<String, Object?> node) {
    final settings = SubscriptionParser._map(node['settings']);
    SubscriptionParser._checkKeys(settings, {'address', 'port'});
    final stream = SubscriptionParser._map(node['streamSettings']);
    SubscriptionParser._checkKeys(stream, {
      'network',
      'security',
      'tlsSettings',
      'masqueSettings',
    });
    if (stream['network'] != 'masque' || stream['security'] != 'tls') {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final auth = SubscriptionParser._map(stream['masqueSettings']);
    SubscriptionParser._checkKeys(auth, {'user', 'pass'});
    final tls = SubscriptionParser._map(stream['tlsSettings']);
    SubscriptionParser._checkKeys(tls, {'serverName', 'alpn', 'allowInsecure'});
    if (tls.containsKey('allowInsecure') && tls['allowInsecure'] != false) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final alpn = tls['alpn'] ?? <String>[];
    if (alpn is! List ||
        alpn.any((value) => value is! String) ||
        settings['port'] is! int) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return _make(
      name: SubscriptionParser._string(node['tag'] ?? ''),
      protocol: ProxyProtocol.masque,
      server: SubscriptionParser._string(settings['address']),
      port: SubscriptionParser._integer(settings['port']),
      username: SubscriptionParser._string(auth['user']),
      password: SubscriptionParser._string(auth['pass']),
      transport: const Transport(type: 'masque'),
      tls: TlsOptions(
        enabled: true,
        serverName: SubscriptionParser._string(tls['serverName']),
        alpn: alpn.cast<String>(),
      ),
    );
  }

  Map<String, Object?> _additionalSingBox(Map<String, Object?> node) {
    if (node['type'] == 'wireguard') {
      SubscriptionParser._checkKeys(node, {
        'type',
        'tag',
        'server',
        'server_port',
        'private_key',
        'peer_public_key',
        'pre_shared_key',
        'local_address',
        'mtu',
        'reserved',
      });
      return {
        'tag': node['tag'] ?? '',
        'protocol': 'wireguard',
        'settings': {
          'secretKey': node['private_key'],
          'address': node['local_address'],
          if (node.containsKey('mtu')) 'mtu': node['mtu'],
          if (node.containsKey('reserved')) 'reserved': node['reserved'],
          'peers': [
            {
              'endpoint': _endpoint(
                SubscriptionParser._string(node['server']),
                SubscriptionParser._integer(node['server_port']),
              ),
              'publicKey': node['peer_public_key'],
              if (node.containsKey('pre_shared_key'))
                'preSharedKey': node['pre_shared_key'],
            },
          ],
        },
      };
    }
    SubscriptionParser._checkKeys(node, {
      'type',
      'tag',
      'server',
      'server_port',
      'username',
      'password',
      'version',
      'tls',
    });
    if (node.containsKey('version') && node['version'] != '5') {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final tls = node.containsKey('tls')
        ? SubscriptionParser._map(node['tls'])
        : <String, Object?>{};
    SubscriptionParser._checkKeys(tls, {'enabled', 'server_name', 'insecure'});
    if ((tls['enabled'] != null && tls['enabled'] is! bool) ||
        (tls['insecure'] != null && tls['insecure'] != false)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return {
      'tag': node['tag'] ?? '',
      'protocol': node['type'],
      'settings': {
        'servers': [
          {
            'address': node['server'],
            'port': node['server_port'],
            if (node.containsKey('username') || node.containsKey('password'))
              'users': [
                {'user': node['username'], 'pass': node['password']},
              ],
          },
        ],
      },
      'streamSettings': {
        'security': tls['enabled'] == true ? 'tls' : 'none',
        if (tls['enabled'] == true)
          'tlsSettings': {
            if (tls.containsKey('server_name'))
              'serverName': tls['server_name'],
          },
      },
    };
  }

  ConnectionProfile _wireguardOutbound(Map<String, Object?> node) {
    if (node.containsKey('streamSettings')) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final s = SubscriptionParser._map(node['settings']);
    SubscriptionParser._checkKeys(s, {
      'secretKey',
      'address',
      'peers',
      'mtu',
      'reserved',
      'noKernelTun',
    });
    if (s.containsKey('noKernelTun') && s['noKernelTun'] != true) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final peers = s['peers'];
    if (peers is! List || peers.length != 1) {
      throw const _Rejected(ImportIssueCode.unsupportedFeature);
    }
    final peer = SubscriptionParser._map(peers.single);
    SubscriptionParser._checkKeys(peer, {
      'publicKey',
      'preSharedKey',
      'endpoint',
      'allowedIPs',
      'keepAlive',
    });
    // Provider routes are never policy. Only the complete tunnel set is accepted.
    if (peer.containsKey('allowedIPs')) {
      final allowed = peer['allowedIPs'];
      if (allowed is! List ||
          allowed.length != 2 ||
          !allowed.contains('0.0.0.0/0') ||
          !(allowed.contains('::/0') || allowed.contains('::0/0'))) {
        throw const _Rejected(ImportIssueCode.unsupportedFeature);
      }
    }
    final endpoint = Uri.tryParse(
      'udp://${SubscriptionParser._string(peer['endpoint'])}',
    );
    if (endpoint == null ||
        !endpoint.hasPort ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.path.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    final addresses = s['address'];
    final reserved = s.containsKey('reserved')
        ? _wireguardReserved(s['reserved'])
        : <int>[];
    if (addresses is! List || addresses.any((x) => x is! String)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
    return _make(
      name: SubscriptionParser._string(node['tag'] ?? ''),
      protocol: ProxyProtocol.wireguard,
      server: endpoint.host,
      port: endpoint.port,
      transport: const Transport(),
      tls: TlsOptions(enabled: false),
      wireguard: WireGuardOptions(
        privateKey: SubscriptionParser._string(s['secretKey']),
        publicKey: SubscriptionParser._string(peer['publicKey']),
        preSharedKey: SubscriptionParser._optional(peer['preSharedKey']),
        addresses: addresses.cast<String>(),
        mtu: SubscriptionParser._integer(s['mtu'] ?? 1420),
        keepAlive: SubscriptionParser._integer(peer['keepAlive'] ?? 0),
        reserved: reserved,
      ),
    );
  }
}

String _endpoint(String host, int port) =>
    '${host.contains(':') ? '[$host]' : host}:$port';

void _validateAdditional(
  ProxyProtocol protocol,
  Transport t,
  TlsOptions tls,
  String? username,
  String? password,
  WireGuardOptions? wg,
) {
  final proxy =
      protocol == ProxyProtocol.socks5 || protocol == ProxyProtocol.http;
  final masque = protocol == ProxyProtocol.masque;
  if ((username != null && !proxy && !masque) ||
      (wg != null) != (protocol == ProxyProtocol.wireguard)) {
    throw const _Rejected(ImportIssueCode.invalidProfile);
  }
  if (masque &&
      (t.type != 'masque' ||
          t.toJson().length != 1 ||
          !tls.enabled ||
          tls.serverName == null ||
          tls.serverName!.isEmpty ||
          !SubscriptionParser._validHost(tls.serverName!) ||
          tls.fingerprint != null ||
          tls.reality != null ||
          !(tls.alpn.isEmpty ||
              (tls.alpn.length == 1 && tls.alpn.single == 'h3')) ||
          username == null ||
          username.isEmpty ||
          username.contains(':') ||
          !SubscriptionParser._clean(username, 255) ||
          password == null ||
          password.isEmpty ||
          !SubscriptionParser._clean(password, 255))) {
    throw const _Rejected(ImportIssueCode.invalidProfile);
  }
  if (proxy &&
      (t.type != 'tcp' ||
          t.toJson().length != 1 ||
          tls.reality != null ||
          (username == null) != (password == null) ||
          (username != null &&
              (username.isEmpty ||
                  !SubscriptionParser._clean(username, 255) ||
                  password!.isEmpty ||
                  !SubscriptionParser._clean(password, 255))))) {
    throw const _Rejected(ImportIssueCode.invalidProfile);
  }
  if (wg != null) {
    if (t.toJson().length != 1 ||
        t.type != 'tcp' ||
        tls.enabled ||
        username != null ||
        password != null ||
        !wg.isValid ||
        (wg.reserved.isNotEmpty && wg.reserved.length != 3) ||
        wg.reserved.any((x) => x < 0 || x > 255)) {
      throw const _Rejected(ImportIssueCode.invalidProfile);
    }
  }
}
