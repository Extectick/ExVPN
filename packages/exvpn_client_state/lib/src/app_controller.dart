import 'dart:async';
import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';

import 'presentation_models.dart';
import 'subscription_name.dart';

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
  final Map<String, PendingSubscriptionUpdate> _pendingUpdates = {};
  String? _selectedGroupId;
  String? _selectedServerId;
  String? _selectedAutomaticGroupId;
  int _nextGroup = 1;
  bool _disposed = false;

  List<SubscriptionGroup> get groups => List.unmodifiable(_groups);
  String? get selectedGroupId => _selectedGroupId;
  String? get selectedServerId => _selectedServerId;
  String? get selectedAutomaticGroupId => _selectedAutomaticGroupId;
  bool get isDemo => _groups.any((group) => group.isDemo);
  bool get showAddSubscriptionButton => _groups.isEmpty;
  Stream<void> get changes => _changes.stream;

  /// A bounded, normalized candidate kept only in memory. The working list
  /// remains authoritative until this exact candidate is explicitly accepted.
  PendingSubscriptionUpdate? pendingUpdate(String groupId) =>
      _pendingUpdates[groupId];

  /// Starting a newer download invalidates an old confirmation even if that
  /// download subsequently fails. The accepted list and diagnostics stay put.
  void discardPendingUpdate(String groupId) {
    _ensureAlive();
    if (_pendingUpdates.remove(groupId) != null) _notify();
  }

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
    String name = '',
    String? providerName,
    required String raw,
    String? sourceUrl,
  }) {
    _ensureAlive();
    _validateSourceUrl(sourceUrl);
    final result = _parser.parse(raw);
    final explicitName = safeSubscriptionName(name, sourceUrl: sourceUrl);
    final metadataName = safeSubscriptionName(
      providerName,
      sourceUrl: sourceUrl,
    );
    final id = 'subscription-${_nextGroup++}';
    _groups = [
      ..._groups,
      SubscriptionGroup(
        id: id,
        name: explicitName ?? metadataName ?? 'Подписка',
        providerName: metadataName,
        nameIsAutomatic: explicitName == null,
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

  /// Apply supported records automatically when the rest are only unsupported
  /// or ignored local settings. Malformed/empty replacements retain working
  /// content and metadata, including when the previous group is empty.
  SubscriptionImportResult updateSubscription({
    required String groupId,
    required String raw,
    String? providerName,
    String? sourceUrl,
    bool clearSourceUrl = false,
  }) {
    _ensureAlive();
    _validateSourceUrl(sourceUrl);
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) throw StateError('Subscription no longer exists.');
    final group = _groups[index];
    final result = _parser.parse(raw);
    final metadataName = safeSubscriptionName(
      providerName,
      sourceUrl: sourceUrl ?? group.sourceUrl,
    );
    final onlySkippableIssues = result.issues.every(
      (issue) => switch (issue.code) {
        ImportIssueCode.unsupportedProtocol ||
        ImportIssueCode.unsupportedFeature ||
        ImportIssueCode.ignoredLocalConfiguration => true,
        _ => false,
      },
    );
    final apply = result.profiles.isNotEmpty && onlySkippableIssues;
    final servers = result.profiles
        .map((profile) => ServerEntry(profile: profile))
        .toList();
    // Every parsed replacement invalidates an older confirmation, including
    // an entirely invalid response. Never accept a superseded HTTP body.
    _pendingUpdates.remove(groupId);
    if (!apply && servers.isNotEmpty) {
      _pendingUpdates[groupId] = PendingSubscriptionUpdate._(
        groupId: groupId,
        previousCount: group.servers.length,
        expectedRevision: group.contentRevision,
        servers: servers,
        issues: result.issues,
        sourceUrl: sourceUrl,
        clearSourceUrl: clearSourceUrl,
        providerName: metadataName,
      );
    }
    _groups = [
      for (var i = 0; i < _groups.length; i++)
        if (i == index)
          group.copyWith(
            name: apply && group.nameIsAutomatic ? metadataName : null,
            providerName: apply ? metadataName : null,
            servers: apply ? servers : null,
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

  /// Accepts only the exact current candidate from this controller. No fetching,
  /// reparsing, or tunnel changes happen after the user's confirmation.
  bool acceptPartialUpdate(PendingSubscriptionUpdate candidate) {
    _ensureAlive();
    final index = _groups.indexWhere((g) => g.id == candidate.groupId);
    if (index < 0 ||
        !identical(_pendingUpdates[candidate.groupId], candidate) ||
        _groups[index].contentRevision != candidate._expectedRevision) {
      return false;
    }
    final group = _groups[index];
    _pendingUpdates.remove(candidate.groupId);
    _groups = [
      for (var i = 0; i < _groups.length; i++)
        if (i == index)
          group.copyWith(
            name: group.nameIsAutomatic ? candidate._providerName : null,
            providerName: candidate._providerName,
            servers: candidate._servers,
            issues: candidate.issues,
            isDemo: false,
            sourceUrl: candidate._sourceUrl,
            clearSourceUrl: candidate._clearSourceUrl,
            updatedAt: _nowUtcMillis(),
            contentRevision: group.contentRevision + 1,
          )
        else
          _groups[i],
    ];
    _restoreSelection(preferredGroupId: candidate.groupId);
    _notify();
    return true;
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
    if (_selectedGroupId == groupId &&
        _selectedServerId == serverId &&
        _selectedAutomaticGroupId == null) {
      return true;
    }
    _selectedGroupId = groupId;
    _selectedServerId = serverId;
    _selectedAutomaticGroupId = null;
    _notify();
    return true;
  }

  /// A local choice, never enabled by provider routing or a restored VPN state.
  bool selectAutomaticGroup(String groupId) {
    _ensureAlive();
    final group = _groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null || group.isDemo || group.servers.length < 2) return false;
    _selectedAutomaticGroupId = groupId;
    _selectedGroupId = groupId;
    if (!group.servers.any((s) => s.id == _selectedServerId)) {
      _selectedServerId = group.servers.first.id;
    }
    _notify();
    return true;
  }

  bool removeSubscription(String groupId) {
    _ensureAlive();
    if (!_groups.any((group) => group.id == groupId)) return false;
    _pendingUpdates.remove(groupId);
    _groups = _groups.where((group) => group.id != groupId).toList();
    _restoreSelection();
    _notify();
    return true;
  }

  /// Metadata edits preserve the accepted profiles and selection. Advancing the
  /// revision fences pending downloads/confirmations from the previous source.
  bool editSubscription({
    required String groupId,
    required String name,
    String? sourceUrl,
  }) {
    _ensureAlive();
    _validateSourceUrl(sourceUrl);
    final index = _groups.indexWhere((group) => group.id == groupId);
    if (index == -1) return false;
    final group = _groups[index];
    final explicitName = safeSubscriptionName(name, sourceUrl: sourceUrl);
    if (name.trim().isNotEmpty && explicitName == null) {
      throw const FormatException('Invalid subscription name.');
    }
    final automatic =
        name.trim().isEmpty ||
        (explicitName == group.name && group.nameIsAutomatic);
    final displayName = explicitName ?? group.providerName ?? group.name;
    final sourceChanged = sourceUrl != group.sourceUrl;
    if (!sourceChanged &&
        displayName == group.name &&
        automatic == group.nameIsAutomatic) {
      return true;
    }
    _pendingUpdates.remove(groupId);
    _groups = [
      for (var i = 0; i < _groups.length; i++)
        if (i == index)
          group.copyWith(
            name: displayName,
            nameIsAutomatic: automatic,
            sourceUrl: sourceUrl,
            clearSourceUrl: sourceUrl == null,
            issues: sourceChanged ? const [] : null,
            updatedAt: sourceChanged
                ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
                : null,
            contentRevision: group.contentRevision + 1,
          )
        else
          _groups[i],
    ];
    _notify();
    return true;
  }

  void _restoreSelection({String? preferredGroupId}) {
    if (!_groups.any(
      (g) =>
          g.id == _selectedAutomaticGroupId &&
          !g.isDemo &&
          g.servers.length >= 2,
    )) {
      _selectedAutomaticGroupId = null;
    }
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
    _pendingUpdates.clear();
    _selectedGroupId = null;
    _selectedServerId = null;
    _selectedAutomaticGroupId = null;
    unawaited(_changes.close());
  }
}

/// Safe preview fields contain counts and fixed parser codes only. Profiles and
/// source credentials are private; candidates are deliberately not serialized.
final class PendingSubscriptionUpdate {
  PendingSubscriptionUpdate._({
    required this.groupId,
    required this.previousCount,
    required int expectedRevision,
    required List<ServerEntry> servers,
    required List<ImportIssue> issues,
    required String? sourceUrl,
    required bool clearSourceUrl,
    required String? providerName,
  }) : _expectedRevision = expectedRevision,
       _servers = List.unmodifiable(servers),
       issues = List.unmodifiable(issues),
       _sourceUrl = sourceUrl,
       _clearSourceUrl = clearSourceUrl,
       _providerName = providerName;

  final String groupId;
  final int previousCount;
  final int _expectedRevision;
  final List<ServerEntry> _servers;
  final List<ImportIssue> issues;
  final String? _sourceUrl;
  final bool _clearSourceUrl;
  final String? _providerName;
  int get supportedCount => _servers.length;

  @override
  String toString() => 'PendingSubscriptionUpdate(<redacted>)';
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
