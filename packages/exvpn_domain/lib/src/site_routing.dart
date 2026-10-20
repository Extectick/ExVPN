// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

/// Local destination policy. Provider subscriptions cannot modify these rules.
enum SiteRoutingMode { disabled, exclude, include }

const maxSiteRules = 1024;
const maxSavedSitePresets = 8;
const maxTotalSiteRules = 2048;

Never _invalidSitePolicy() =>
    throw const FormatException('site_routing_rejected');

/// A domain includes its subdomains; IPs and networks are literal destinations.
/// URLs/wildcards are a convenience at the UI boundary, never native config.
String normalizeSiteRule(String input, {bool allowUrl = true}) {
  var value = input.trim();
  if (value.isEmpty ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(value)) {
    _invalidSitePolicy();
  }
  if (value.contains('://')) {
    if (!allowUrl) _invalidSitePolicy();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _invalidSitePolicy();
    }
    value = uri.host;
  }
  if (allowUrl && value.startsWith('*.')) value = value.substring(2);
  if (value.runes.any((r) => r < 33 || r > 126)) _invalidSitePolicy();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  final split = value.split('/');
  if (split.length > 2) _invalidSitePolicy();
  var bytes = _ipBytes(split.first);
  if (bytes != null) {
    int? prefix;
    if (split.length == 2) {
      if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(split.last)) {
        _invalidSitePolicy();
      }
      prefix = int.parse(split.last);
      if (prefix > bytes.length * 8) _invalidSitePolicy();
    }
    final mapped =
        bytes.length == 16 &&
        bytes.take(10).every((v) => v == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255;
    if (mapped && (prefix == null || prefix >= 96)) {
      bytes = bytes.sublist(12);
      if (prefix != null) prefix -= 96;
    }
    if (prefix != null) {
      for (var i = 0; i < bytes.length; i++) {
        final bits = (prefix - i * 8).clamp(0, 8);
        bytes[i] &= (255 << (8 - bits)) & 255;
      }
    }
    final ip = _formatIp(bytes);
    return prefix == null ? ip : '$ip/$prefix';
  }
  if (split.length != 1 ||
      value.contains(':') ||
      RegExp(r'^[0-9.]+$').hasMatch(value)) {
    _invalidSitePolicy();
  }
  value = value.toLowerCase();
  if (value.endsWith('.')) value = value.substring(0, value.length - 1);
  final labels = value.split('.');
  if (value.length > 253 ||
      labels.length < 2 ||
      !RegExp(r'[a-z]').hasMatch(labels.last) ||
      labels.any(
        (label) =>
            !RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(label),
      )) {
    _invalidSitePolicy();
  }
  return value;
}

List<int>? _ipv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4 ||
      parts.any((part) => !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part))) {
    return null;
  }
  final bytes = parts.map(int.parse).toList();
  return bytes.any((v) => v > 255) ? null : bytes;
}

List<int>? _ipBytes(String value) {
  if (!value.contains(':')) return _ipv4(value);
  if (value.contains('%')) return null;
  var text = value.toLowerCase();
  if (text.contains('.')) {
    final pos = text.lastIndexOf(':');
    final tail = _ipv4(text.substring(pos + 1));
    if (tail == null) return null;
    text =
        '${text.substring(0, pos + 1)}${((tail[0] << 8) | tail[1]).toRadixString(16)}:${((tail[2] << 8) | tail[3]).toRadixString(16)}';
  }
  final halves = text.split('::');
  if (halves.length > 2) return null;
  List<String> words(String text) => text.isEmpty ? [] : text.split(':');
  final left = words(halves.first);
  final right = halves.length == 2 ? words(halves.last) : <String>[];
  final count = left.length + right.length;
  if ((halves.length == 1 && count != 8) ||
      (halves.length == 2 && count >= 8)) {
    return null;
  }
  final all = [
    ...left,
    if (halves.length == 2) ...List.filled(8 - count, '0'),
    ...right,
  ];
  if (all.any((word) => !RegExp(r'^[a-f0-9]{1,4}$').hasMatch(word))) {
    return null;
  }
  return all.expand((word) {
    final v = int.parse(word, radix: 16);
    return [v >> 8, v & 255];
  }).toList();
}

String _formatIp(List<int> bytes) {
  if (bytes.length == 4) return bytes.join('.');
  final words = [
    for (var i = 0; i < 16; i += 2) (bytes[i] << 8) | bytes[i + 1],
  ];
  var best = -1, length = 1;
  for (var i = 0; i < 8;) {
    if (words[i] != 0) {
      i++;
      continue;
    }
    var end = i;
    while (end < 8 && words[end] == 0) {
      end++;
    }
    if (end - i > length) {
      best = i;
      length = end - i;
    }
    i = end;
  }
  String join(Iterable<int> values) =>
      values.map((v) => v.toRadixString(16)).join(':');
  return best < 0
      ? join(words)
      : '${join(words.take(best))}::${join(words.skip(best + length))}';
}

final class SiteRoutingPolicy {
  SiteRoutingPolicy({required this.mode, Iterable<String> rules = const []})
    : rules = List.unmodifiable(rules) {
    if (this.rules.length > maxSiteRules ||
        this.rules.toSet().length != this.rules.length) {
      _invalidSitePolicy();
    }
    for (final rule in this.rules) {
      if (normalizeSiteRule(rule, allowUrl: false) != rule) {
        _invalidSitePolicy();
      }
    }
  }
  final SiteRoutingMode mode;
  final List<String> rules;
  bool get active =>
      mode == SiteRoutingMode.include ||
      (mode == SiteRoutingMode.exclude && rules.isNotEmpty);
  Map<String, Object?> toJson() => {'mode': mode.name, 'rules': rules};
  factory SiteRoutingPolicy.fromJson(Object? value) {
    final map = _siteObject(value, {'mode', 'rules'});
    final mode = SiteRoutingMode.values
        .where((v) => v.name == map['mode'])
        .firstOrNull;
    if (mode == null) _invalidSitePolicy();
    return SiteRoutingPolicy(mode: mode, rules: _siteStrings(map['rules']));
  }
}

final class SiteRoutingPreset {
  SiteRoutingPreset({
    required this.id,
    required this.name,
    required this.policy,
  }) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.trim() != name ||
        name.runes.length > 80 ||
        RegExp(r'[\p{Cc}\p{Cf}\u2028\u2029]', unicode: true).hasMatch(name)) {
      _invalidSitePolicy();
    }
  }
  final String id, name;
  final SiteRoutingPolicy policy;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'policy': policy.toJson(),
  };
  factory SiteRoutingPreset.fromJson(Object? value) {
    final map = _siteObject(value, {'id', 'name', 'policy'});
    if (map['id'] is! String || map['name'] is! String) _invalidSitePolicy();
    return SiteRoutingPreset(
      id: map['id'] as String,
      name: map['name'] as String,
      policy: SiteRoutingPolicy.fromJson(map['policy']),
    );
  }
}

final class SiteRoutingState {
  SiteRoutingState({
    required this.policy,
    Iterable<SiteRoutingPreset> savedPresets = const [],
    this.selectedPreset = 'russia-basic',
  }) : savedPresets = List.unmodifiable(savedPresets) {
    if (this.savedPresets.length > maxSavedSitePresets ||
        this.savedPresets.map((p) => p.id).toSet().length !=
            this.savedPresets.length ||
        policy.rules.length +
                this.savedPresets.fold<int>(
                  0,
                  (n, p) => n + p.policy.rules.length,
                ) >
            maxTotalSiteRules ||
        (selectedPreset.isNotEmpty &&
            !RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(selectedPreset)) ||
        utf8
                .encode(
                  jsonEncode(toJson()).replaceAllMapped(
                    RegExp(r'[<>&]'),
                    (m) =>
                        '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
                  ),
                )
                .length >
            512 << 10) {
      _invalidSitePolicy();
    }
  }
  factory SiteRoutingState.disabled() => SiteRoutingState(
    policy: SiteRoutingPolicy(mode: SiteRoutingMode.disabled),
  );
  final SiteRoutingPolicy policy;
  final List<SiteRoutingPreset> savedPresets;
  final String selectedPreset;
  Map<String, Object?> toJson() => {
    'schema': 1,
    'policy': policy.toJson(),
    'savedPresets': savedPresets.map((p) => p.toJson()).toList(),
    'selectedPreset': selectedPreset,
  };
  factory SiteRoutingState.fromJson(Object? value) {
    final map = _siteObject(value, {
      'schema',
      'policy',
      'savedPresets',
      'selectedPreset',
    });
    final presets = map['savedPresets'];
    if (map['schema'] is! int ||
        map['schema'] != 1 ||
        presets is! List ||
        presets.length > maxSavedSitePresets ||
        map['selectedPreset'] is! String) {
      _invalidSitePolicy();
    }
    return SiteRoutingState(
      policy: SiteRoutingPolicy.fromJson(map['policy']),
      savedPresets: presets.map(SiteRoutingPreset.fromJson),
      selectedPreset: map['selectedPreset'] as String,
    );
  }
}

Map<Object?, Object?> _siteObject(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      value.keys.any((k) => !keys.contains(k))) {
    _invalidSitePolicy();
  }
  return Map<Object?, Object?>.from(value);
}

List<String> _siteStrings(Object? value) {
  if (value is! List ||
      value.length > maxSiteRules ||
      value.any((v) => v is! String)) {
    _invalidSitePolicy();
  }
  return value.cast<String>();
}

abstract interface class SiteRoutingBridge {
  Future<SiteRoutingState> getSiteRouting();
  Future<void> setSiteRouting(SiteRoutingState state);
}
