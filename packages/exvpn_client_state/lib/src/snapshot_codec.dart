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
  final t = _object(p['transport'], {
    'type',
    'path',
    'host',
    'serviceName',
    'mode',
  });
  final type = _text(t['type'], max: 16);
  if (!{'tcp', 'ws', 'grpc', 'xhttp'}.contains(type)) _invalidSnapshot();
  final tls = _object(p['tls'], {
    'enabled',
    'serverName',
    'fingerprint',
    'alpn',
    'reality',
  });
  RealityOptions? reality;
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
    cipher: _optional(p['cipher'], max: 128),
    flow: _optional(p['flow'], max: 128),
    transport: Transport(
      type: type,
      path: _optional(t['path']),
      host: _optional(t['host']),
      serviceName: _optional(t['serviceName']),
      mode: _optional(t['mode'], max: 128),
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
    });
    if (snapshot['version'] is! int || snapshot['version'] != 1) {
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
      .._selectedServerId = _optional(snapshot['selectedServerId'], max: 64);
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
    'version': 1,
    'selectedGroupId': selectedReal ? controller.selectedGroupId : null,
    'selectedServerId': selectedReal ? controller.selectedServerId : null,
    'groups': [
      for (final group in groups)
        <String, Object?>{
          'id': group.id,
          'name': group.name,
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
