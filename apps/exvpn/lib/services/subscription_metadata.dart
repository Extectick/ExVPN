// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';

/// Normalized response metadata, never a source URL or an executable config.
/// The body is still passed intact to the existing bounded profile parser.
final class SubscriptionDocument {
  const SubscriptionDocument({required this.body, this.providerName});
  factory SubscriptionDocument.fromText(
    String body, {
    Map<String, String> headers = const {},
  }) {
    final normalized = {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final title =
        _title(normalized['profile-title']) ??
        _bodyTitle(body) ??
        _filename(normalized['content-disposition']);
    return SubscriptionDocument(body: body, providerName: title);
  }
  final String body;
  final String? providerName;
  @override
  String toString() => 'SubscriptionDocument(<redacted>)';
}

String? _title(String? value) {
  if (value == null || value.length > 4096) return null;
  var title = value.trim();
  if (title.toLowerCase().startsWith('base64:')) {
    try {
      title = utf8.decode(base64.decode(base64.normalize(title.substring(7))));
    } on FormatException {
      return null;
    }
  }
  return safeSubscriptionName(title);
}

String? _filename(String? value) {
  if (value == null || value.length > 4096) return null;
  final extended = RegExp(
    r"(?:^|;)\s*filename\*\s*=\s*UTF-8'[^']*'([^;]+)",
    caseSensitive: false,
  ).firstMatch(value);
  if (extended != null) {
    try {
      final name = Uri.decodeComponent(extended.group(1)!.trim());
      final safe = _fileTitle(name);
      if (safe != null) return safe;
    } on FormatException {
      // An invalid extended parameter does not invalidate a plain filename.
    }
  }
  final plain = RegExp(
    r'(?:^|;)\s*filename\s*=\s*(?:"([^"\r\n]*)"|([^;]*))',
    caseSensitive: false,
  ).firstMatch(value);
  return plain == null ? null : _fileTitle(plain.group(1) ?? plain.group(2)!);
}

String? _fileTitle(String value) => _title(
  value.trim().replaceFirst(
    RegExp(r'\.(?:txt|json|conf|yaml|yml)$', caseSensitive: false),
    '',
  ),
);

String? _bodyTitle(String raw) {
  const maxBytes = 2 * 1024 * 1024;
  if (raw.length > maxBytes) return null;
  var text = raw.replaceFirst('\uFEFF', '').trim();
  if (!text.contains('://') && !text.startsWith('{') && !text.startsWith('[')) {
    try {
      text = utf8
          .decode(
            base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))),
          )
          .trim();
    } on FormatException {
      return null;
    }
  }
  if (text.length > maxBytes) return null;
  if (text.startsWith('{')) {
    // Match the parser's bounded nesting before jsonDecode; metadata must never
    // turn a malformed or deeply nested document into an unbounded operation.
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          quoted = false;
        }
      } else if (unit == 34) {
        quoted = true;
      } else if (unit == 123 || unit == 91) {
        if (++depth > 32) return null;
      } else if (unit == 125 || unit == 93) {
        depth--;
      }
    }
    try {
      final data = jsonDecode(text);
      if (data is Map<String, dynamic> && data['outbounds'] is List) {
        for (final key in ['profile-title', 'remarks', 'name']) {
          final value = data[key];
          final title = value is String ? _title(value) : null;
          if (title != null) return title;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(
      r'^\s*#\s*profile-title\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) continue;
    final title = _title(match.group(1));
    if (title != null) return title;
  }
  return null;
}
