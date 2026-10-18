import 'package:exvpn_domain/exvpn_domain.dart';

/// Presentation metadata around a secret-bearing, normalized profile.
final class ServerEntry {
  ServerEntry({
    required this.profile,
    String? countryCode,
    this.latencyMs,
    this.isDemo = false,
  }) : countryCode = countryCode ?? _countryFromFlag(profile.name) {
    if (latencyMs != null && (!isDemo || latencyMs! < 0)) {
      throw ArgumentError('Only DEMO entries may have preview latency.');
    }
    if (this.countryCode != null &&
        !RegExp(r'^[A-Z]{2}$').hasMatch(this.countryCode!)) {
      throw ArgumentError('Country code must contain two uppercase letters.');
    }
  }

  final ConnectionProfile profile;
  final String? countryCode;

  /// Synthetic preview values, never a measurement of a real endpoint.
  final int? latencyMs;
  final bool isDemo;

  String get id => profile.id;

  /// Move an explicit flag into the flag column. Do not geolocate hosts
  /// or guess a country from a server name.
  String get name {
    final trimmed = profile.name.trim();
    final flag = _flagPattern.firstMatch(trimmed);
    if (flag == null) return trimmed;
    final withoutFlag = trimmed.replaceRange(flag.start, flag.end, '').trim();
    return withoutFlag.isEmpty ? trimmed : withoutFlag;
  }

  String get protocolLabel {
    final protocol = switch (profile.protocol) {
      ProxyProtocol.vless => 'VLESS',
      ProxyProtocol.vmess => 'VMess',
      ProxyProtocol.trojan => 'Trojan',
      ProxyProtocol.shadowsocks => 'Shadowsocks',
      ProxyProtocol.hysteria2 => 'Hysteria2',
    };
    final labels = <String>[protocol];
    if (profile.transport.type != 'tcp') {
      labels.add(profile.transport.type.toUpperCase());
    }
    if (profile.tls.reality != null) {
      labels.add('Reality');
    } else if (profile.tls.enabled &&
        profile.transport.type == 'tcp' &&
        profile.protocol != ProxyProtocol.hysteria2) {
      labels.add('TLS');
    }
    return labels.join(' · ');
  }

  @override
  String toString() => 'ServerEntry(<redacted>, demo: $isDemo)';
}

final _flagPattern = RegExp('[\u{1f1e6}-\u{1f1ff}]{2}', unicode: true);

String? _countryFromFlag(String name) {
  final match = _flagPattern.firstMatch(name);
  if (match == null) return null;
  final runes = match.group(0)!.runes;
  return String.fromCharCodes(runes.map((rune) => rune - 0x1f1e6 + 65));
}

/// An immutable subscription group. An existing empty group is not equivalent
/// to having no subscriptions: its diagnostics remain visible to the user.
final class SubscriptionGroup {
  SubscriptionGroup({
    required this.id,
    required this.name,
    this.providerName,
    this.nameIsAutomatic = false,
    required List<ServerEntry> servers,
    this.expanded = true,
    List<ImportIssue> issues = const [],
    this.isDemo = false,
    this.sourceUrl,
    this.updatedAt,
    this.contentRevision = 0,
  }) : servers = List.unmodifiable(servers),
       issues = List.unmodifiable(issues);

  final String id;
  final String name;

  /// Sanitized provider metadata. A manually supplied name remains authoritative.
  final String? providerName;
  final bool nameIsAutomatic;
  final List<ServerEntry> servers;
  final bool expanded;
  final List<ImportIssue> issues;
  final bool isDemo;

  /// Secret-bearing provider URL. Persist only through the secure store.
  final String? sourceUrl;
  final DateTime? updatedAt;

  /// Runtime-only version of accepted subscription content/source. Unlike a
  /// timestamp, this distinguishes consecutive updates in the same millisecond.
  final int contentRevision;

  SubscriptionGroup copyWith({
    String? name,
    String? providerName,
    List<ServerEntry>? servers,
    bool? expanded,
    List<ImportIssue>? issues,
    bool? isDemo,
    String? sourceUrl,
    bool clearSourceUrl = false,
    DateTime? updatedAt,
    int? contentRevision,
  }) => SubscriptionGroup(
    id: id,
    name: name ?? this.name,
    providerName: providerName ?? this.providerName,
    nameIsAutomatic: nameIsAutomatic,
    servers: servers ?? this.servers,
    expanded: expanded ?? this.expanded,
    issues: issues ?? this.issues,
    isDemo: isDemo ?? this.isDemo,
    sourceUrl: clearSourceUrl ? null : sourceUrl ?? this.sourceUrl,
    updatedAt: updatedAt ?? this.updatedAt,
    contentRevision: contentRevision ?? this.contentRevision,
  );

  @override
  String toString() =>
      'SubscriptionGroup(<redacted>, ${servers.length} servers)';
}

final class SubscriptionImportResult {
  SubscriptionImportResult({
    required this.groupId,
    required this.applied,
    required List<ImportIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final String groupId;

  /// Whether the parsed profiles became the group's current list.
  final bool applied;
  final List<ImportIssue> issues;
}
