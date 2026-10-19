// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const independentOtaAppId = 'ea97a683-02e5-4d86-9aa1-779d6b4bc81e';
const independentOtaEngine = '4b936a0c03e13389ddfb1ac48823f187964975c2';
const independentOtaKeyId = 'exvpn-full-update-beta-1';
const independentOtaPublicKey = 'jqfYwATCfBPz1x8MDwBCj7ova7Ju9fdJIWCnLDGWLNk=';
const independentOtaDomain = 'ExVPN/dart-update/v1\x00';
const independentOtaPort = 57791;
const independentOtaMaxDiff = 64 * 1024 * 1024;
const independentOtaMaxCatalog = 256 * 1024;
const independentOtaFeed =
    'https://github.com/Extectick/ExVPN/releases/download/ota-beta/dart-updates.json';

class IndependentOtaFailure implements Exception {
  const IndependentOtaFailure(this.code);
  final String code;
}

Never _bad([String code = 'catalog_invalid']) =>
    throw IndependentOtaFailure(code);
bool _keys(Map<String, dynamic> value, Set<String> keys) =>
    value.length == keys.length && keys.containsAll(value.keys);
final _sha = RegExp(r'^[a-f0-9]{64}$');
bool _number(Object? value) => value is int && value > 0 && value <= 2147483647;

/// Canonical compact ASCII rejects duplicate keys, alternate numeric forms,
/// excessive whitespace and ambiguous encodings before trusting signed fields.
Map<String, dynamic> decodeIndependentOtaJson(List<int> bytes, int limit) {
  try {
    if (bytes.isEmpty || bytes.length > limit) _bad();
    final raw = utf8.decode(bytes);
    if (raw.codeUnits.any((c) => c > 127)) _bad();
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || jsonEncode(value) != raw.trim()) {
      _bad();
    }
    return value;
  } on IndependentOtaFailure {
    rethrow;
  } catch (_) {
    _bad();
  }
}

DateTime _date(Object? raw) {
  if (raw is! String ||
      !RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$').hasMatch(raw)) {
    _bad();
  }
  final value = DateTime.tryParse(raw);
  if (value == null ||
      value.toIso8601String().replaceFirst('.000Z', 'Z') != raw) {
    _bad();
  }
  return value;
}

Uint8List _base64(Object? raw, int length) {
  try {
    if (raw is! String) _bad();
    final bytes = base64Decode(raw);
    if (bytes.length != length || base64Encode(bytes) != raw) _bad();
    return bytes;
  } on IndependentOtaFailure {
    rethrow;
  } catch (_) {
    _bad();
  }
}

class IndependentOtaPatch {
  const IndependentOtaPatch({
    required this.platform,
    required this.arch,
    required this.number,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    required this.aotSha256,
    required this.signature,
  });
  final String platform, arch, sha256, aotSha256, signature;
  final int number, sizeBytes;
  final Uri url;
  String get target => '$platform/$arch';

  static IndependentOtaPatch decode(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        !_keys(raw, {
          'platform',
          'arch',
          'number',
          'url',
          'sha256',
          'sizeBytes',
          'aotSha256',
          'signature',
        })) {
      _bad();
    }
    final platform = raw['platform'], arch = raw['arch'];
    if (!{
      'windows/x86_64',
      'android/aarch64',
      'android/x86_64',
    }.contains('$platform/$arch')) {
      _bad();
    }
    if (!_number(raw['number']) ||
        raw['sizeBytes'] is! int ||
        raw['sizeBytes'] < 1 ||
        raw['sizeBytes'] > independentOtaMaxDiff ||
        raw['sha256'] is! String ||
        !_sha.hasMatch(raw['sha256']) ||
        raw['aotSha256'] is! String ||
        !_sha.hasMatch(raw['aotSha256'])) {
      _bad();
    }
    _base64(raw['signature'], 512); // pinned RSA4096 PKCS#1 signature
    final urlRaw = raw['url'];
    if (urlRaw is! String || urlRaw.length > 2048) _bad();
    final url = Uri.tryParse(urlRaw);
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.fragment.isNotEmpty ||
        urlRaw.contains('%') ||
        !RegExp(
          r'^/Extectick/ExVPN/releases/download/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.patch$',
        ).hasMatch(url.path)) {
      _bad();
    }
    return IndependentOtaPatch(
      platform: platform,
      arch: arch,
      number: raw['number'],
      url: url,
      sha256: raw['sha256'],
      sizeBytes: raw['sizeBytes'],
      aotSha256: raw['aotSha256'],
      signature: raw['signature'],
    );
  }

  bool sameCode(IndependentOtaPatch other) =>
      number == other.number &&
      target == other.target &&
      url == other.url &&
      sha256 == other.sha256 &&
      sizeBytes == other.sizeBytes &&
      aotSha256 == other.aotSha256 &&
      signature == other.signature;
}

class IndependentOtaBase {
  const IndependentOtaBase(
    this.version,
    this.compatibility,
    this.patches,
    this.revoked,
  );
  final String version, compatibility;
  final List<IndependentOtaPatch> patches;
  final Set<int> revoked;
  IndependentOtaPatch? patch(String platform, String arch) {
    for (final value in patches) {
      if (value.platform == platform && value.arch == arch) return value;
    }
    return null;
  }
}

class IndependentOtaCatalog {
  const IndependentOtaCatalog._(
    this.revision,
    this.expiresAt,
    this.bases,
    this.envelope,
  );
  final int revision;
  final DateTime expiresAt;
  final List<IndependentOtaBase> bases;
  final Uint8List envelope;

  IndependentOtaBase? base(String version, String compatibility) {
    for (final value in bases) {
      if (value.version == version && value.compatibility == compatibility) {
        return value;
      }
    }
    return null;
  }

  static Future<IndependentOtaCatalog> verify(
    Uint8List bytes, {
    required DateTime now,
    required String track,
    bool allowExpired = false,
    List<int>? publicKey,
  }) async {
    if (track != 'beta' && track != 'stable') _bad();
    final envelope = decodeIndependentOtaJson(bytes, independentOtaMaxCatalog);
    if (!_keys(envelope, {'schema', 'keyId', 'payload', 'signature'}) ||
        envelope['schema'] is! int ||
        envelope['schema'] != 1 ||
        envelope['keyId'] != independentOtaKeyId ||
        envelope['payload'] is! String) {
      _bad();
    }
    Uint8List payload;
    try {
      payload = base64Decode(envelope['payload']);
      if (base64Encode(payload) != envelope['payload']) _bad();
    } catch (_) {
      _bad();
    }
    final signature = _base64(envelope['signature'], 64);
    final valid = await Ed25519().verify(
      [...utf8.encode(independentOtaDomain), ...payload],
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          publicKey ?? base64Decode(independentOtaPublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) _bad('signature_invalid');
    final body = decodeIndependentOtaJson(
      payload,
      independentOtaMaxCatalog * 3 ~/ 4,
    );
    if (!_keys(body, {
          'schema',
          'appId',
          'channel',
          'revision',
          'publishedAt',
          'expiresAt',
          'bases',
        }) ||
        body['schema'] is! int ||
        body['schema'] != 1 ||
        body['appId'] != independentOtaAppId ||
        body['channel'] != track ||
        !_number(body['revision']) ||
        body['bases'] is! List ||
        (body['bases'] as List).length > 16) {
      _bad();
    }
    final published = _date(body['publishedAt']),
        expires = _date(body['expiresAt']);
    if (published.isAfter(now.add(const Duration(minutes: 2))) ||
        !expires.isAfter(published) ||
        expires.difference(published) > const Duration(days: 30) ||
        (!allowExpired && !expires.isAfter(now))) {
      _bad('catalog_expired');
    }
    final bases = <IndependentOtaBase>[], identities = <String>{};
    for (final raw in body['bases']) {
      if (raw is! Map<String, dynamic> ||
          !_keys(raw, {
            'version',
            'engineRevision',
            'compatibilitySha256',
            'patches',
            'revoked',
          }) ||
          raw['version'] is! String ||
          !RegExp(
            r'^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\+[1-9][0-9]{0,8}$',
          ).hasMatch(raw['version']) ||
          raw['engineRevision'] != independentOtaEngine ||
          raw['compatibilitySha256'] is! String ||
          !_sha.hasMatch(raw['compatibilitySha256']) ||
          !identities.add(raw['version']) ||
          raw['patches'] is! List ||
          (raw['patches'] as List).length > 3 ||
          raw['revoked'] is! List ||
          (raw['revoked'] as List).length > 4096) {
        _bad();
      }
      final revoked = <int>{};
      for (final number in raw['revoked']) {
        if (!_number(number) || !revoked.add(number as int)) _bad();
      }
      final patches = <IndependentOtaPatch>[], targets = <String>{};
      for (final item in raw['patches']) {
        final patch = IndependentOtaPatch.decode(item);
        if (!targets.add(patch.target) || revoked.contains(patch.number)) {
          _bad();
        }
        patches.add(patch);
      }
      bases.add(
        IndependentOtaBase(
          raw['version'],
          raw['compatibilitySha256'],
          List.unmodifiable(patches),
          Set.unmodifiable(revoked),
        ),
      );
    }
    return IndependentOtaCatalog._(
      body['revision'],
      expires,
      List.unmodifiable(bases),
      Uint8List.fromList(bytes),
    );
  }

  /// Withdrawal is cumulative; a patch number may never acquire new contents.
  void requireSuccessorOf(IndependentOtaCatalog previous) {
    if (revision < previous.revision ||
        (revision == previous.revision &&
            base64Encode(envelope) != base64Encode(previous.envelope))) {
      _bad('catalog_replayed');
    }
    for (final oldBase in previous.bases) {
      final next = base(oldBase.version, oldBase.compatibility);
      if (next == null) _bad('withdrawal_missing');
      if (!next.revoked.containsAll(oldBase.revoked)) {
        _bad('withdrawal_replayed');
      }
      for (final old in oldBase.patches) {
        final current = next.patch(old.platform, old.arch);
        if (current == null) {
          if (!next.revoked.contains(old.number)) _bad('withdrawal_missing');
        } else if (current.number < old.number ||
            (current.number == old.number && !current.sameCode(old))) {
          _bad('patch_replayed');
        }
      }
    }
  }
}
