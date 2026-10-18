// SPDX-License-Identifier: Apache-2.0

/// Display names are data, never URLs, credentials, paths, or markup. Keep the
/// same bounds at import and at the persistence boundary.
String? safeSubscriptionName(String? input, {String? sourceUrl}) {
  if (input == null || input.length > 4096) return null;
  final text = input
      .replaceAll(
        RegExp(
          r'[\x00-\x20\x7f-\x9f\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u2028-\u202e\u2060-\u206f\u3164\ufeff\uffa0]',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty ||
      text.contains(RegExp(r'[\\<>]')) ||
      text.startsWith('/') ||
      text.contains(RegExp(r'(?:^|\s)\.{1,2}/')) ||
      text.contains(RegExp(r'\b[a-z][a-z0-9+.-]*://', caseSensitive: false)) ||
      text.contains(RegExp(r'\b[a-f0-9]{48,}\b', caseSensitive: false)) ||
      text.contains(
        RegExp(
          r'[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}',
        ),
      )) {
    return null;
  }
  final source = sourceUrl == null ? null : Uri.tryParse(sourceUrl);
  if (source != null) {
    final privateParts = [
      ...source.pathSegments.where((part) => part.length >= 12),
      ...source.queryParametersAll.values
          .expand((parts) => parts)
          .where((part) => part.length >= 8),
    ];
    if (privateParts.any(text.contains)) return null;
  }
  return String.fromCharCodes(text.runes.take(80));
}
