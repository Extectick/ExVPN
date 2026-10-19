part of 'subscription_parser.dart';

extension _AdditionalProtocols on SubscriptionParser {
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
    final reserved = s['reserved'] ?? <Object>[];
    if (addresses is! List ||
        addresses.any((x) => x is! String) ||
        reserved is! List ||
        reserved.any((x) => x is! int)) {
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
        reserved: reserved.cast<int>(),
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
  if ((username != null && !proxy) ||
      (wg != null) != (protocol == ProxyProtocol.wireguard)) {
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
