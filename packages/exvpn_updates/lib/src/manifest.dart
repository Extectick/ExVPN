// SPDX-License-Identifier: Apache-2.0
part of '../exvpn_updates.dart';

final class ManifestVerifier {
  ManifestVerifier(this.policy);
  final TrustedUpdatePolicy policy;

  Future<VerifiedManifest> verify(List<int> envelopeBytes) async {
    if (envelopeBytes.length > policy.limits.envelopeBytes) {
      _fail(UpdateError.tooLarge);
    }
    final input = List<int>.unmodifiable(envelopeBytes);
    final Map<String, Object?> envelope;
    try {
      envelope = _JsonReader(utf8.decode(input)).object();
      _keys(envelope, {'keyId', 'manifest', 'signature'});
    } catch (_) {
      _fail(UpdateError.invalidEnvelope);
    }
    final keyId = envelope['keyId'];
    if (keyId is! String || !policy.publicKeys.containsKey(keyId)) {
      _fail(UpdateError.untrustedKey);
    }
    final List<int> raw, signature;
    try {
      raw = base64.decode(envelope['manifest'] as String);
      signature = base64.decode(envelope['signature'] as String);
    } catch (_) {
      _fail(UpdateError.invalidEnvelope);
    }
    if (raw.isEmpty ||
        raw.length > policy.limits.manifestBytes ||
        signature.length != 64) {
      _fail(UpdateError.invalidEnvelope);
    }
    bool valid;
    try {
      valid = await Ed25519().verify(
        raw,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(
            policy.publicKeys[keyId]!,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      valid = false;
    }
    if (!valid) _fail(UpdateError.invalidSignature);
    // Parse the exact verified bytes. Never re-encode a JSON object for signature checking.
    try {
      final data = _JsonReader(utf8.decode(raw)).object();
      _keys(
        data,
        {
          'format',
          'revision',
          'channel',
          'minVersion',
          'maxVersionExclusive',
          'minBuild',
          'maxBuild',
          'files',
        },
        optional: {'rollbackOf'},
      );
      _integer(data['format'], 1, 1);
      final revision = _integer(data['revision'], 1, _maxInteger);
      final channel = UpdateChannel.values.firstWhere(
        (v) => v.name == data['channel'],
      );
      final minVersion = AppVersion.parse(data['minVersion'] as String);
      final maxVersion = AppVersion.parse(
        data['maxVersionExclusive'] as String,
      );
      final minBuild = _integer(data['minBuild'], 1, _maxInteger);
      final maxBuild = _integer(data['maxBuild'], minBuild, _maxInteger);
      if (minVersion.compareTo(maxVersion) >= 0) {
        _fail(UpdateError.invalidManifest);
      }
      final rollback = data.containsKey('rollbackOf')
          ? _integer(data['rollbackOf'], 1, revision - 1)
          : null;
      final entries = data['files'];
      if (entries is! List ||
          entries.isEmpty ||
          entries.length > policy.limits.maxFiles) {
        _fail(UpdateError.invalidManifest);
      }
      final files = <ResourceFile>[];
      final paths = <String>{};
      var total = 0;
      for (final entry in entries) {
        if (entry is! Map<String, Object?>) _fail(UpdateError.invalidManifest);
        _keys(entry, {'path', 'size', 'sha256'});
        final path = entry['path'];
        if (path is! String ||
            !_safeResourcePath(path) ||
            !policy.resourceLimits.containsKey(path) ||
            !paths.add(path)) {
          _fail(UpdateError.pathDenied);
        }
        final size = _integer(entry['size'], 0, policy.resourceLimits[path]!);
        final hash = entry['sha256'];
        if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
          _fail(UpdateError.invalidManifest);
        }
        total += size;
        if (total > policy.limits.bundleBytes) _fail(UpdateError.tooLarge);
        files.add(ResourceFile._(path, size, hash));
      }
      if (!paths.containsAll(policy.requiredPaths)) {
        _fail(UpdateError.invalidManifest);
      }
      return VerifiedManifest._(
        revision: revision,
        channel: channel,
        minVersion: minVersion,
        maxVersionExclusive: maxVersion,
        minBuild: minBuild,
        maxBuild: maxBuild,
        files: List.unmodifiable(files),
        envelope: input,
        sha256: digest.sha256.convert(raw).toString(),
        rollbackOf: rollback,
      );
    } on UpdateException {
      rethrow;
    } catch (_) {
      _fail(UpdateError.invalidManifest);
    }
  }
}

int _integer(Object? value, int low, int high) {
  if (value is! int || value < low || value > high) {
    _fail(UpdateError.invalidManifest);
  }
  return value;
}

void _keys(
  Map<String, Object?> value,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    _fail(UpdateError.invalidManifest);
  }
}

/// Bounded recursive JSON parsing also rejects duplicate object keys. The normal
/// jsonDecode silently discards duplicates, which is unsuitable at this boundary.
final class _JsonReader {
  _JsonReader(this.source);
  final String source;
  int at = 0;
  Map<String, Object?> object() {
    final result = _value(0);
    _space();
    if (at != source.length || result is! Map<String, Object?>) {
      throw const FormatException();
    }
    return result;
  }

  void _space() {
    while (at < source.length && ' \t\r\n'.contains(source[at])) {
      at++;
    }
  }

  bool _take(String c) {
    _space();
    if (at < source.length && source[at] == c) {
      at++;
      return true;
    }
    return false;
  }

  void _expect(String c) {
    if (!_take(c)) throw const FormatException();
  }

  String _string() {
    _space();
    final start = at;
    if (at >= source.length || source[at++] != '"') {
      throw const FormatException();
    }
    while (at < source.length) {
      final c = source[at++];
      if (c == '"') return jsonDecode(source.substring(start, at)) as String;
      if (c == r'\') at++;
    }
    throw const FormatException();
  }

  Object? _value(int depth) {
    if (depth > 16) throw const FormatException();
    _space();
    if (at >= source.length) throw const FormatException();
    if (source[at] == '"') return _string();
    if (_take('{')) {
      final value = <String, Object?>{};
      if (_take('}')) return value;
      do {
        final key = _string();
        if (value.containsKey(key)) throw const FormatException();
        _expect(':');
        value[key] = _value(depth + 1);
        if (_take('}')) return value;
        _expect(',');
      } while (true);
    }
    if (_take('[')) {
      final value = <Object?>[];
      if (_take(']')) return value;
      do {
        value.add(_value(depth + 1));
        if (_take(']')) return value;
        _expect(',');
      } while (true);
    }
    final start = at;
    while (at < source.length && !' \t\r\n,]}'.contains(source[at])) {
      at++;
    }
    if (start == at) throw const FormatException();
    return jsonDecode(source.substring(start, at));
  }
}
