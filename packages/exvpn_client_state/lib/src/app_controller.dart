import 'dart:async';

import 'package:exvpn_domain/exvpn_domain.dart';

import 'presentation_models.dart';

part 'snapshot_codec.dart';

/// Presentation state. Does not fetch subscriptions, save secrets, measure
/// endpoints, start a VPN, or manufacture a connected/protected state.
final class AppController {
  AppController({SubscriptionParser parser = const SubscriptionParser()})
    : _parser = parser;

  factory AppController.demo() {
    final controller = AppController();
    controller._groups = _demoGroups();
    controller._restoreSelection();
    return controller;
  }

  /// Restore only a bounded, versioned snapshot from protected storage.
  factory AppController.fromSnapshot(Map<String, dynamic> snapshot) =>
      _decodeSnapshot(snapshot);

  /// Contains secrets. This map must only be passed to protected storage.
  Map<String, Object?> exportSnapshot() => _encodeSnapshot(this);

  final SubscriptionParser _parser;
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  List<SubscriptionGroup> _groups = const [];
  String? _selectedGroupId;
  String? _selectedServerId;
  int _nextGroup = 1;
  bool _disposed = false;

  List<SubscriptionGroup> get groups => List.unmodifiable(_groups);
  String? get selectedGroupId => _selectedGroupId;
  String? get selectedServerId => _selectedServerId;
  bool get isDemo => _groups.any((group) => group.isDemo);
  bool get showAddSubscriptionButton => _groups.isEmpty;
  Stream<void> get changes => _changes.stream;

  ServerEntry? get selectedServer {
    for (final group in _groups) {
      if (group.id != _selectedGroupId) continue;
      for (final server in group.servers) {
        if (server.id == _selectedServerId) return server;
      }
    }
    return null;
  }

  /// Raw input is parsed and discarded. Only normalized profiles and safe issue
  /// codes remain in memory. HTTPS subscription URLs are not fetched here.
  SubscriptionImportResult addSubscription({
    required String name,
    required String raw,
    String? sourceUrl,
  }) {
    _ensureAlive();
    _validateSourceUrl(sourceUrl);
    final result = _parser.parse(raw);
    final id = 'subscription-${_nextGroup++}';
    _groups = [
      ..._groups,
      SubscriptionGroup(
        id: id,
        name: name.trim().isEmpty ? 'Подписка' : name.trim(),
        servers: result.profiles
            .map((profile) => ServerEntry(profile: profile))
            .toList(),
        issues: result.issues,
        sourceUrl: sourceUrl,
        updatedAt: result.profiles.isEmpty ? null : _nowUtcMillis(),
      ),
    ];
    _restoreSelection();
    _notify();
    return SubscriptionImportResult(
      groupId: id,
      applied: result.profiles.isNotEmpty,
      issues: result.issues,
    );
  }

  /// Failed or partially malformed replacement cannot erase a working list.
  /// An empty group may accept supported records while retaining all issues.
  SubscriptionImportResult updateSubscription({
    required String groupId,
    required String raw,
    String? sourceUrl,
    bool clearSourceUrl = false,
  }) {
    _ensureAlive();
    _validateSourceUrl(sourceUrl);
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) throw StateError('Subscription no longer exists.');
    final group = _groups[index];
    final result = _parser.parse(raw);
    final hasErrors = result.issues.any(
      (issue) => issue.code != ImportIssueCode.ignoredLocalConfiguration,
    );
    final apply =
        result.profiles.isNotEmpty && (group.servers.isEmpty || !hasErrors);
    _groups = [
      for (var i = 0; i < _groups.length; i++)
        if (i == index)
          group.copyWith(
            servers: apply
                ? result.profiles
                      .map((profile) => ServerEntry(profile: profile))
                      .toList()
                : null,
            issues: result.issues,
            isDemo: apply ? false : group.isDemo,
            sourceUrl: apply ? sourceUrl : null,
            clearSourceUrl: apply && clearSourceUrl,
            updatedAt: apply ? _nowUtcMillis() : null,
            contentRevision: apply ? group.contentRevision + 1 : null,
          )
        else
          _groups[i],
    ];
    _restoreSelection(preferredGroupId: groupId);
    _notify();
    return SubscriptionImportResult(
      groupId: groupId,
      applied: apply,
      issues: result.issues,
    );
  }

  bool toggleGroup(String groupId) {
    _ensureAlive();
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) return false;
    _groups = [
      for (var i = 0; i < _groups.length; i++)
        if (i == index)
          _groups[i].copyWith(expanded: !_groups[i].expanded)
        else
          _groups[i],
    ];
    _notify();
    return true;
  }

  bool selectServer({required String groupId, required String serverId}) {
    _ensureAlive();
    final exists = _groups.any(
      (group) =>
          group.id == groupId &&
          group.servers.any((server) => server.id == serverId),
    );
    if (!exists) return false;
    if (_selectedGroupId == groupId && _selectedServerId == serverId) {
      return true;
    }
    _selectedGroupId = groupId;
    _selectedServerId = serverId;
    _notify();
    return true;
  }

  bool removeSubscription(String groupId) {
    _ensureAlive();
    if (!_groups.any((group) => group.id == groupId)) return false;
    _groups = _groups.where((group) => group.id != groupId).toList();
    _restoreSelection();
    _notify();
    return true;
  }

  void _restoreSelection({String? preferredGroupId}) {
    if (selectedServer != null) return;
    _selectedGroupId = null;
    _selectedServerId = null;
    final candidates = [
      ..._groups.where((group) => group.id == preferredGroupId),
      ..._groups.where((group) => group.id != preferredGroupId),
    ];
    for (final group in candidates) {
      if (group.servers.isEmpty) continue;
      _selectedGroupId = group.id;
      _selectedServerId = group.servers.first.id;
      return;
    }
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('Controller is disposed.');
  }

  void _notify() => _changes.add(null);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _groups = const [];
    _selectedGroupId = null;
    _selectedServerId = null;
    unawaited(_changes.close());
  }
}

DateTime _nowUtcMillis() => DateTime.fromMillisecondsSinceEpoch(
  DateTime.now().millisecondsSinceEpoch,
  isUtc: true,
);

List<SubscriptionGroup> _demoGroups() {
  ServerEntry server(
    String id,
    String name,
    String country,
    ProxyProtocol protocol,
    int latency, {
    String transport = 'tcp',
    bool reality = false,
  }) => ServerEntry(
    profile: ConnectionProfile(
      id: 'demo-$id',
      name: name,
      protocol: protocol,
      server: '$id.invalid',
      port: 443,
      transport: Transport(type: transport),
      tls: TlsOptions(
        enabled: protocol != ProxyProtocol.shadowsocks,
        reality: reality
            ? const RealityOptions(
                publicKey: 'DEMO-NOT-A-REAL-KEY',
                shortId: '',
              )
            : null,
      ),
    ),
    countryCode: country,
    latencyMs: latency,
    isDemo: true,
  );

  return [
    SubscriptionGroup(
      id: 'demo-main',
      name: 'Основная подписка',
      isDemo: true,
      servers: [
        server(
          'amsterdam',
          'Амстердам',
          'NL',
          ProxyProtocol.vless,
          42,
          reality: true,
        ),
        server(
          'frankfurt',
          'Франкфурт',
          'DE',
          ProxyProtocol.vless,
          58,
          transport: 'xhttp',
        ),
        server('helsinki', 'Хельсинки', 'FI', ProxyProtocol.hysteria2, 67),
        server('warsaw', 'Варшава', 'PL', ProxyProtocol.trojan, 73),
      ],
    ),
    SubscriptionGroup(
      id: 'demo-backup',
      name: 'Резервная подписка',
      expanded: false,
      isDemo: true,
      servers: [
        server('paris', 'Париж', 'FR', ProxyProtocol.vmess, 81),
        server('stockholm', 'Стокгольм', 'SE', ProxyProtocol.shadowsocks, 75),
      ],
    ),
  ];
}
