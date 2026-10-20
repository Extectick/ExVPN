part of 'app_controller.dart';

/// Safe error: never includes a malformed value or an underlying exception.
final class SnapshotFormatException implements Exception {
  const SnapshotFormatException();
  @override
  String toString() => 'SnapshotFormatException(invalid_snapshot)';
}

Never _invalidSnapshot() => throw const SnapshotFormatException();

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !keys.contains(key))) {
    _invalidSnapshot();
  }
  return value;
}

String _text(Object? value, {int max = 16384, bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.isEmpty) ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _invalidSnapshot();
  }
  return value;
}

String? _optional(Object? value, {int max = 16384}) =>
    value == null ? null : _text(value, max: max, empty: true);

String _subscriptionName(Object? value) {
  final text = _text(value, max: 160);
  if (safeSubscriptionName(text) != text) _invalidSnapshot();
  return text;
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _invalidSnapshot();
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) _invalidSnapshot();
  return value;
}

List<dynamic> _list(Object? value, int max) {
  if (value is! List || value.length > max) _invalidSnapshot();
  return value;
}

void _validateSourceUrl(String? source) {
  if (source == null) return;
  try {
    final text = _text(source, max: 8192);
    final uri = Uri.parse(text);
    if (RegExp(r'\s').hasMatch(text) ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      _invalidSnapshot();
    }
  } on FormatException {
    _invalidSnapshot();
  }
}

ConnectionProfile _profile(Object? value) {
  final p = _object(value, {
    'id',
    'name',
    'protocol',
    'server',
    'port',
    'uuid',
    'password',
    'cipher',
    'flow',
    'encryption',
    'packetEncoding',
    'username',
    'wireguard',
    'transport',
    'tls',
  });
  final id = _text(p['id'], max: 64);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) _invalidSnapshot();
  final protocolName = _text(p['protocol'], max: 32);
  final protocol = ProxyProtocol.values
      .where((v) => v.name == protocolName)
      .firstOrNull;
  if (protocol == null) _invalidSnapshot();
  WireGuardOptions? wireguard;
  if (p['wireguard'] != null) {
    final w = _object(p['wireguard'], {
      'privateKey',
      'publicKey',
      'preSharedKey',
      'addresses',
      'mtu',
      'reserved',
      'keepAlive',
    });
    final addresses = w['addresses'];
    final reserved = w['reserved'] ?? <Object>[];
    if (addresses is! List ||
        addresses.isEmpty ||
        addresses.length > 2 ||
        addresses.any((x) => x is! String) ||
        reserved is! List ||
        (reserved.isNotEmpty && reserved.length != 3)) {
      _invalidSnapshot();
    }
    wireguard = WireGuardOptions(
      privateKey: _text(w['privateKey'], max: 128),
      publicKey: _text(w['publicKey'], max: 128),
      preSharedKey: _optional(w['preSharedKey'], max: 128),
      addresses: addresses.cast<String>(),
      mtu: _integer(w['mtu'], 1280, 1420),
      keepAlive: w['keepAlive'] == null ? 0 : _integer(w['keepAlive'], 0, 120),
      reserved: reserved.map((x) => _integer(x, 0, 255)).toList(),
    );
  }
  if ((wireguard != null) != (protocol == ProxyProtocol.wireguard) ||
      (p['username'] != null &&
          !{
            ProxyProtocol.socks5,
            ProxyProtocol.http,
            ProxyProtocol.masque,
          }.contains(protocol))) {
    _invalidSnapshot();
  }
  final t = _object(p['transport'], {
    'type',
    'path',
    'host',
    'serviceName',
    'mode',
    'tcpSudoku',
    'tcpKeepAliveIdle',
    'tcpKeepAliveInterval',
    'wsEarlyDataHeaderName',
  });
  final type = _text(t['type'], max: 16);
  final packetEncoding = _optional(p['packetEncoding'], max: 16);
  final earlyDataHeader = _optional(t['wsEarlyDataHeaderName'], max: 64);
  if ((packetEncoding != null &&
          (packetEncoding != 'xudp' || protocol != ProxyProtocol.vless)) ||
      (earlyDataHeader != null &&
          (earlyDataHeader != 'Sec-WebSocket-Protocol' || type != 'ws'))) {
    _invalidSnapshot();
  }
  if (!{'tcp', 'ws', 'grpc', 'xhttp', 'hysteria', 'masque'}.contains(type) ||
      (protocol == ProxyProtocol.masque) != (type == 'masque')) {
    _invalidSnapshot();
  }
  if ((p.containsKey('encryption') && p['encryption'] == null) ||
      (t.containsKey('tcpSudoku') && t['tcpSudoku'] == null)) {
    _invalidSnapshot();
  }
  final encryption = p['encryption'] == null
      ? null
      : VlessEncryption.parse(_text(p['encryption'], max: 8192));
  final sudoku = t['tcpSudoku'] == null
      ? null
      : SudokuOptions.fromJson(
          _object(t['tcpSudoku'], {
            'password',
            'ascii',
            'customTables',
            'paddingMin',
            'paddingMax',
          }),
        );
  final tls = _object(p['tls'], {
    'enabled',
    'serverName',
    'fingerprint',
    'alpn',
    'reality',
  });
  final tcpProxy = {
    ProxyProtocol.socks5,
    ProxyProtocol.http,
  }.contains(protocol);
  if (protocol == ProxyProtocol.masque) {
    if (t.length != 1 ||
        tls['enabled'] != true ||
        [
          'uuid',
          'cipher',
          'flow',
          'encryption',
          'packetEncoding',
        ].any(p.containsKey)) {
      _invalidSnapshot();
    }
    // Reuse the same bounded credential/TLS/SNI validation as untrusted imports.
    // This has no network or persistence side effects and never exports input.
    final validated = const SubscriptionParser().parse(
      jsonEncode({
        'outbounds': [
          {
            'protocol': 'masque',
            'settings': {'address': p['server'], 'port': p['port']},
            'streamSettings': {
              'network': 'masque',
              'security': 'tls',
              'masqueSettings': {'user': p['username'], 'pass': p['password']},
              'tlsSettings': {
                'serverName': tls['serverName'],
                if (tls.containsKey('alpn')) 'alpn': tls['alpn'],
                if (tls.containsKey('fingerprint'))
                  'fingerprint': tls['fingerprint'],
              },
              if (tls.containsKey('reality')) 'realitySettings': tls['reality'],
            },
          },
        ],
      }),
    );
    if (validated.profiles.length != 1 || validated.issues.isNotEmpty) {
      _invalidSnapshot();
    }
  }
  if ((tcpProxy || protocol == ProxyProtocol.wireguard) &&
      (type != 'tcp' ||
          t.length != 1 ||
          [
            'uuid',
            'cipher',
            'flow',
            'encryption',
            'packetEncoding',
          ].any(p.containsKey))) {
    _invalidSnapshot();
  }
  if (tcpProxy &&
      ((p['username'] == null) != (p['password'] == null) ||
          (p['username'] != null &&
              (_text(p['username'], max: 255).isEmpty ||
                  _text(p['password'], max: 255).isEmpty)) ||
          tls['reality'] != null)) {
    _invalidSnapshot();
  }
  if (protocol == ProxyProtocol.wireguard &&
      (p['password'] != null ||
          p['username'] != null ||
          tls['enabled'] != false ||
          tls.length != 1)) {
    _invalidSnapshot();
  }
  RealityOptions? reality;
  if ((encryption != null && protocol != ProxyProtocol.vless) ||
      (sudoku != null &&
          (protocol != ProxyProtocol.vless ||
              type != 'tcp' ||
              (tls['enabled'] != true && encryption == null)))) {
    _invalidSnapshot();
  }
  if (tls['reality'] != null) {
    final r = _object(tls['reality'], {'publicKey', 'shortId', 'spiderX'});
    reality = RealityOptions(
      publicKey: _text(r['publicKey'], max: 256),
      shortId: _text(r['shortId'], max: 32, empty: true),
      spiderX: _optional(r['spiderX']),
    );
  }
  return ConnectionProfile(
    id: id,
    name: _text(p['name'], max: 4096),
    protocol: protocol,
    server: _text(p['server'], max: 253),
    port: _integer(p['port'], 1, 65535),
    uuid: _optional(p['uuid'], max: 128),
    password: _optional(p['password']),
    username: _optional(p['username'], max: 255),
    wireguard: wireguard,
    cipher: _optional(p['cipher'], max: 128),
    flow: _optional(p['flow'], max: 128),
    encryption: encryption,
    packetEncoding: packetEncoding,
    transport: Transport(
      type: type,
      path: _optional(t['path']),
      host: _optional(t['host']),
      serviceName: _optional(t['serviceName']),
      mode: _optional(t['mode'], max: 128),
      tcpSudoku: sudoku,
      tcpKeepAliveIdle: t['tcpKeepAliveIdle'] == null
          ? null
          : _integer(t['tcpKeepAliveIdle'], 1, 86400),
      tcpKeepAliveInterval: t['tcpKeepAliveInterval'] == null
          ? null
          : _integer(t['tcpKeepAliveInterval'], 1, 86400),
      wsEarlyDataHeaderName: earlyDataHeader,
    ),
    tls: TlsOptions(
      enabled: _boolean(tls['enabled']),
      serverName: _optional(tls['serverName'], max: 253),
      fingerprint: _optional(tls['fingerprint'], max: 128),
      alpn: tls['alpn'] == null
          ? []
          : _list(tls['alpn'], 32).map((v) => _text(v, max: 255)).toList(),
      reality: reality,
    ),
  );
}

AppController _decodeSnapshot(Map<String, dynamic> value) {
  try {
    final snapshot = _object(value, {
      'version',
      'groups',
      'selectedGroupId',
      'selectedServerId',
      'selectedAutomaticGroupId',
    });
    if (snapshot['version'] is! int ||
        !{1, 2, 3}.contains(snapshot['version'])) {
      _invalidSnapshot();
    }
    final groups = <SubscriptionGroup>[];
    final ids = <String>{};
    var totalProfiles = 0;
    var nextId = 1;
    for (final item in _list(snapshot['groups'], 100)) {
      final group = _object(item, {
        'id',
        'name',
        'providerName',
        'nameIsAutomatic',
        'expanded',
        'profiles',
        'issues',
        'sourceUrl',
        'updatedAt',
      });
      final id = _text(group['id'], max: 40);
      final number = RegExp(r'^subscription-([1-9][0-9]{0,8})$').firstMatch(id);
      if (number == null || !ids.add(id)) _invalidSnapshot();
      final next = int.parse(number.group(1)!) + 1;
      if (next > nextId) nextId = next;
      final profiles = _list(group['profiles'], 5000).map(_profile).toList();
      totalProfiles += profiles.length;
      if (totalProfiles > 10000 ||
          profiles.map((p) => p.id).toSet().length != profiles.length) {
        _invalidSnapshot();
      }
      final issues = <ImportIssue>[];
      for (final value in _list(group['issues'], 5001)) {
        final issue = _object(value, {'index', 'code'});
        final code = ImportIssueCode.values
            .where((v) => v.name == issue['code'])
            .firstOrNull;
        if (code == null) _invalidSnapshot();
        issues.add(ImportIssue(_integer(issue['index'], 0, 10000000), code));
      }
      final source = _optional(group['sourceUrl'], max: 8192);
      _validateSourceUrl(source);
      final updatedAt = group['updatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              _integer(group['updatedAt'], 0, 8640000000000000),
              isUtc: true,
            );
      groups.add(
        SubscriptionGroup(
          id: id,
          name: _text(group['name'], max: 512),
          providerName: group['providerName'] == null
              ? null
              : _subscriptionName(group['providerName']),
          nameIsAutomatic: group.containsKey('nameIsAutomatic')
              ? _boolean(group['nameIsAutomatic'])
              : false,
          servers: profiles.map((p) => ServerEntry(profile: p)).toList(),
          expanded: _boolean(group['expanded']),
          issues: issues,
          sourceUrl: source,
          updatedAt: updatedAt,
        ),
      );
    }
    final result = AppController()
      .._groups = groups
      .._nextGroup = nextId
      .._selectedGroupId = _optional(snapshot['selectedGroupId'], max: 40)
      .._selectedServerId = _optional(snapshot['selectedServerId'], max: 64)
      .._selectedAutomaticGroupId = _optional(
        snapshot['selectedAutomaticGroupId'],
        max: 40,
      );
    if (result._selectedAutomaticGroupId != null &&
        result._selectedAutomaticGroupId != result._selectedGroupId) {
      _invalidSnapshot();
    }
    result._restoreSelection();
    return result;
  } on SnapshotFormatException {
    rethrow;
  } catch (_) {
    _invalidSnapshot();
  }
}

Map<String, Object?> _encodeSnapshot(AppController controller) {
  controller._ensureAlive();
  final groups = controller.groups.where((g) => !g.isDemo).toList();
  final selectedReal = groups.any((g) => g.id == controller.selectedGroupId);
  final result = <String, Object?>{
    'version': 3,
    'selectedGroupId': selectedReal ? controller.selectedGroupId : null,
    'selectedServerId': selectedReal ? controller.selectedServerId : null,
    'selectedAutomaticGroupId': selectedReal
        ? controller.selectedAutomaticGroupId
        : null,
    'groups': [
      for (final group in groups)
        <String, Object?>{
          'id': group.id,
          'name': group.name,
          'providerName': group.providerName,
          'nameIsAutomatic': group.nameIsAutomatic,
          'expanded': group.expanded,
          'sourceUrl': group.sourceUrl,
          'updatedAt': group.updatedAt?.millisecondsSinceEpoch,
          'profiles': [
            for (final server in group.servers) server.profile.toNativeJson(),
          ],
          'issues': [
            for (final issue in group.issues)
              {'index': issue.index, 'code': issue.code.name},
          ],
        },
    ],
  };
  // Fail before touching storage if a future producer violates the bounded schema.
  _decodeSnapshot(result).dispose();
  return result;
}
