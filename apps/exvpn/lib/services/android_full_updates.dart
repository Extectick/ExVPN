// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'app_updates_types.dart';

const androidUpdateFeed =
    'https://github.com/Extectick/ExVPN/releases/download/android-beta/android.json';
const androidUpdateKeyId = 'exvpn-full-update-beta-1';
const androidUpdatePublicKey = 'jqfYwATCfBPz1x8MDwBCj7ova7Ju9fdJIWCnLDGWLNk=';
const androidUpdateDomain = 'ExVPN/android-update/v1\x00';
const androidUpdateMaxApkBytes = 512 * 1024 * 1024;

Never _fail(String code) => throw AppUpdatesFailure(code);
bool _keys(Map<String, dynamic> value, Set<String> keys) =>
    value.length == keys.length && value.keys.toSet().containsAll(keys);
final _semver = RegExp(
  r'^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$',
);
int _compareVersion(String left, String right) {
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

/// Strict compact JSON prevents duplicate fields rather than accepting the last
/// value. This protocol contains only ASCII fields; signing uses these bytes.
Map<String, dynamic> _json(Uint8List bytes, int maximum) {
  try {
    if (bytes.isEmpty || bytes.length > maximum) _fail('manifest_invalid');
    final raw = utf8.decode(bytes);
    if (raw.codeUnits.any((c) => c > 127)) _fail('manifest_invalid');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || jsonEncode(value) != raw.trim()) {
      _fail('manifest_invalid');
    }
    return value;
  } catch (_) {
    _fail('manifest_invalid');
  }
}

DateTime _date(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$').hasMatch(value)) {
    _fail('manifest_invalid');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null ||
      parsed.toIso8601String().replaceFirst('.000Z', 'Z') != value) {
    _fail('manifest_invalid');
  }
  return parsed;
}

class AndroidUpdateContext {
  const AndroidUpdateContext({
    required this.version,
    required this.build,
    required this.sdk,
    required this.cacheDirectory,
  });
  final String version;
  final int build, sdk;
  final Directory cacheDirectory;
  factory AndroidUpdateContext.decode(Object? raw) {
    if (raw is! Map ||
        raw.keys.toSet().difference({
          'version',
          'build',
          'sdk',
          'cacheDirectory',
        }).isNotEmpty ||
        raw.length != 4) {
      _fail('invalid_response');
    }
    final version = raw['version'],
        build = raw['build'],
        sdk = raw['sdk'],
        path = raw['cacheDirectory'];
    if (version is! String ||
        _semver.stringMatch(version) != version ||
        build is! int ||
        build < 1 ||
        sdk is! int ||
        sdk < 30 ||
        path is! String ||
        !path.startsWith('/') ||
        path.contains('\x00')) {
      _fail('invalid_response');
    }
    return AndroidUpdateContext(
      version: version,
      build: build,
      sdk: sdk,
      cacheDirectory: Directory(path),
    );
  }
}

class AndroidUpdateManifest {
  AndroidUpdateManifest._(
    this.version,
    this.build,
    this.minSdk,
    this.url,
    this.sizeBytes,
    this.sha256,
    this.expiresAt,
    this.envelope,
  );
  final String version, sha256;
  final int build, minSdk, sizeBytes;
  final Uri url;
  final DateTime expiresAt;
  final Uint8List envelope;
  String get identity => '$version+$build';
  FullUpdateOffer get offer =>
      FullUpdateOffer(version: identity, sizeBytes: sizeBytes);
  bool newerThan(AndroidUpdateContext context) =>
      build > context.build && _compareVersion(version, context.version) >= 0;

  static Future<AndroidUpdateManifest> verify(
    Uint8List bytes, {
    required DateTime now,
    List<int>? publicKey,
    bool allowExpired = false,
  }) async {
    final envelope = _json(bytes, 32 * 1024);
    if (!_keys(envelope, {'schema', 'keyId', 'payload', 'signature'}) ||
        envelope['schema'] is! int ||
        envelope['schema'] != 1 ||
        envelope['keyId'] != androidUpdateKeyId) {
      _fail('manifest_invalid');
    }
    Uint8List payload, signature;
    try {
      if (envelope['payload'] is! String || envelope['signature'] is! String) {
        _fail('manifest_invalid');
      }
      payload = base64Decode(envelope['payload'] as String);
      signature = base64Decode(envelope['signature'] as String);
      if (base64Encode(payload) != envelope['payload'] ||
          base64Encode(signature) != envelope['signature'] ||
          signature.length != 64) {
        _fail('manifest_invalid');
      }
    } catch (_) {
      _fail('manifest_invalid');
    }
    final valid = await Ed25519().verify(
      [...utf8.encode(androidUpdateDomain), ...payload],
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          publicKey ?? base64Decode(androidUpdatePublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) _fail('signature_invalid');
    final body = _json(payload, 16 * 1024);
    if (!_keys(body, {
          'schema',
          'appId',
          'platform',
          'channel',
          'version',
          'build',
          'publishedAt',
          'expiresAt',
          'minSdk',
          'asset',
        }) ||
        body['schema'] is! int ||
        body['schema'] != 1 ||
        body['appId'] != 'exvpn' ||
        body['platform'] != 'android' ||
        body['channel'] != 'beta') {
      _fail('manifest_invalid');
    }
    final version = body['version'],
        build = body['build'],
        minSdk = body['minSdk'],
        asset = body['asset'];
    if (version is! String ||
        _semver.stringMatch(version) != version ||
        build is! int ||
        build < 1 ||
        build > 2147483647 ||
        minSdk is! int ||
        minSdk < 30 ||
        minSdk > 10000 ||
        asset is! Map<String, dynamic> ||
        !_keys(asset, {'url', 'sizeBytes', 'sha256'})) {
      _fail('manifest_invalid');
    }
    final published = _date(body['publishedAt']),
        expires = _date(body['expiresAt']);
    if (published.isAfter(now) ||
        !expires.isAfter(published) ||
        expires.difference(published) > const Duration(days: 30)) {
      _fail('manifest_invalid');
    }
    if (!allowExpired && !expires.isAfter(now)) _fail('update_expired');
    final url = asset['url'], size = asset['sizeBytes'], sha = asset['sha256'];
    final expected =
        'https://github.com/Extectick/ExVPN/releases/download/v$version/ExVPN-$version-$build-android.apk';
    if (url is! String ||
        url != expected ||
        size is! int ||
        size < 1 ||
        size > androidUpdateMaxApkBytes ||
        sha is! String ||
        sha.length != 64 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      _fail('manifest_invalid');
    }
    return AndroidUpdateManifest._(
      version,
      build,
      minSdk,
      Uri.parse(url),
      size,
      sha,
      expires,
      bytes,
    );
  }
}

abstract interface class AndroidUpdateTransport {
  Future<void> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
    required Future<void> Function(List<int>) onChunk,
  });
  void cancel();
}

class AndroidHttpsUpdateTransport implements AndroidUpdateTransport {
  HttpClient? _client;
  static bool allowedRedirect(Uri uri, Uri initial) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.fragment.isNotEmpty ||
        uri.toString().length > 4096 ||
        uri.toString().split('?').first.contains('%') ||
        uri.path.contains(r'\') ||
        uri.path.contains('//') ||
        uri.pathSegments.any((part) => part == '.' || part == '..')) {
      return false;
    }
    if (uri.host == 'github.com') {
      return uri.path == initial.path && !uri.hasQuery;
    }
    if (uri.host == 'api.github.com') {
      return !uri.hasQuery &&
          RegExp(r'^/repos/Extectick/ExVPN/releases/assets/[1-9][0-9]*$')
              .hasMatch(uri.path);
    }
    if (!{
      'release-assets.githubusercontent.com',
      'objects.githubusercontent.com',
      'github-releases.githubusercontent.com',
    }.contains(uri.host)) {
      return false;
    }
    return uri.path.startsWith('/github-production-release-asset/') ||
        (uri.path.startsWith('/github-production-release-asset-') &&
            uri.path.length > '/github-production-release-asset-'.length);
  }

  static SecurityContext secureContext() =>
      SecurityContext(withTrustedRoots: true)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
  @override
  Future<void> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
    required Future<void> Function(List<int>) onChunk,
  }) async {
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasQuery ||
        uri.fragment.isNotEmpty ||
        !uri.path.startsWith('/Extectick/ExVPN/releases/download/')) {
      _fail('manifest_invalid');
    }
    final client = HttpClient(context: secureContext())
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    try {
      await (() async {
        var current = uri;
        for (var redirects = 0; redirects <= 4; redirects++) {
          final request = await client.getUrl(current);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          final response = await request.close();
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (redirects == 4 || location == null) _fail('network_failed');
            final next = current.resolve(location);
            if (!allowedRedirect(next, uri)) _fail('network_failed');
            await response.listen(null).cancel();
            current = next;
            continue;
          }
          if (response.statusCode != 200 ||
              response.contentLength > maxBytes ||
              (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                      'identity') !=
                  'identity') {
            _fail('download_failed');
          }
          var received = 0;
          await for (final chunk in response) {
            received += chunk.length;
            if (received > maxBytes) _fail('integrity_failed');
            await onChunk(chunk);
          }
          if (response.contentLength >= 0 &&
              response.contentLength != received) {
            _fail('integrity_failed');
          }
          return;
        }
      })().timeout(timeout);
    } on AppUpdatesFailure {
      rethrow;
    } on TimeoutException {
      _fail('timeout');
    } catch (_) {
      _fail('network_failed');
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  @override
  void cancel() {
    _client?.close(force: true);
  }
}

/// Native supplies the private cache and independently validates the final APK.
/// Callers cannot replace the production feed, trust key, URL or package path.
class AndroidFullUpdatesBackend implements FullUpdatesBackend {
  AndroidFullUpdatesBackend({MethodChannel? methods})
    : _methods = methods ?? const MethodChannel('exvpn/app_updates'),
      _transport = AndroidHttpsUpdateTransport(),
      _now = DateTime.now,
      _publicKey = null,
      _testContext = null;
  factory AndroidFullUpdatesBackend.forTesting({
    required MethodChannel methods,
    required AndroidUpdateTransport transport,
    required List<int> publicKey,
    required DateTime Function() now,
    required Future<AndroidUpdateContext> Function() context,
  }) => AndroidFullUpdatesBackend._testing(
    methods,
    transport,
    publicKey,
    now,
    context,
  );
  AndroidFullUpdatesBackend._testing(
    this._methods,
    this._transport,
    this._publicKey,
    this._now,
    this._testContext,
  );
  final MethodChannel _methods;
  final AndroidUpdateTransport _transport;
  final List<int>? _publicKey;
  final DateTime Function() _now;
  final Future<AndroidUpdateContext> Function()? _testContext;
  AndroidUpdateManifest? _selected;
  bool _disposed = false, _cancelled = false, _busy = false;
  Future<void>? _stopped;
  @override
  bool get supported => true;
  Future<Object?> _native(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methods.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      throw AppUpdatesFailure(error.code);
    } on MissingPluginException {
      _fail('updater_unavailable');
    }
  }

  void _active() {
    if (_cancelled || _disposed) _fail('cancelled');
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) _fail('operation_busy');
    _active();
    _busy = true;
    final stopped = Completer<void>();
    _stopped = stopped.future;
    try {
      return await action();
    } on AppUpdatesFailure {
      _active();
      rethrow;
    } catch (_) {
      _fail('cache_unavailable');
    } finally {
      _busy = false;
      stopped.complete();
    }
  }

  Future<AndroidUpdateContext> _context() async {
    final context = _testContext == null
        ? AndroidUpdateContext.decode(await _native('getContext'))
        : await _testContext();
    _active();
    final type = await FileSystemEntity.type(
      context.cacheDirectory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory ||
        await context.cacheDirectory.resolveSymbolicLinks() !=
            context.cacheDirectory.path) {
      _fail('cache_unavailable');
    }
    return context;
  }

  Future<AndroidUpdateManifest> _verify(
    Uint8List bytes, {
    bool allowExpired = false,
  }) => AndroidUpdateManifest.verify(
    bytes,
    now: _now().toUtc(),
    publicKey: _publicKey,
    allowExpired: allowExpired,
  );
  String _nonce() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    final partial = File('${target.path}.${_nonce()}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      _active();
      await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  @override
  Future<FullUpdateOffer?> check() => _exclusive(() async {
    final context = await _context();
    final bytes = BytesBuilder(copy: false);
    await _transport.fetch(
      Uri.parse(androidUpdateFeed),
      maxBytes: 32 * 1024,
      timeout: const Duration(seconds: 30),
      onChunk: (chunk) async {
        _active();
        if (bytes.length + chunk.length > 32 * 1024) _fail('manifest_invalid');
        bytes.add(chunk);
      },
    );
    _active();
    final manifest = await _verify(bytes.takeBytes());
    if (manifest.minSdk > context.sdk) _fail('update_incompatible');
    final receipt = File('${context.cacheDirectory.path}/offer.json');
    final type = await FileSystemEntity.type(receipt.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file ||
          await receipt.length() > 32 * 1024) {
        _fail('cache_unavailable');
      }
      final previous = await _verify(
        await receipt.readAsBytes(),
        allowExpired: true,
      );
      if (manifest.build < previous.build ||
          _compareVersion(manifest.version, previous.version) < 0 ||
          (manifest.build == previous.build &&
              (manifest.identity != previous.identity ||
                  manifest.sha256 != previous.sha256 ||
                  manifest.sizeBytes != previous.sizeBytes))) {
        _fail('manifest_invalid');
      }
    }
    await _writeAtomic(receipt, manifest.envelope);
    _selected = manifest;
    return manifest.newerThan(context) ? manifest.offer : null;
  });
  Future<bool> _validFile(File file, AndroidUpdateManifest manifest) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file ||
        await file.length() != manifest.sizeBytes) {
      _fail('integrity_failed');
    }
    if ((await hashes.sha256.bind(file.openRead()).first).toString() !=
        manifest.sha256) {
      _fail('integrity_failed');
    }
    return true;
  }

  AndroidUpdateManifest _offer(FullUpdateOffer offer) {
    final manifest = _selected;
    if (manifest == null ||
        manifest.identity != offer.version ||
        manifest.sizeBytes != offer.sizeBytes) {
      _fail('update_not_ready');
    }
    if (!manifest.expiresAt.isAfter(_now().toUtc())) _fail('update_expired');
    return manifest;
  }

  @override
  Future<FullUpdateOffer> download(
    FullUpdateOffer offer, {
    required FullUpdateProgressCallback onProgress,
  }) => _exclusive(() async {
    final manifest = _offer(offer), context = await _context();
    if (!manifest.newerThan(context) || manifest.minSdk > context.sdk) {
      _fail('update_incompatible');
    }
    final file = File('${context.cacheDirectory.path}/${manifest.sha256}.apk');
    try {
      if (await _validFile(file, manifest)) {
        onProgress(
          FullUpdateProgress(
            received: manifest.sizeBytes,
            total: manifest.sizeBytes,
          ),
        );
        return manifest.offer;
      }
    } on AppUpdatesFailure catch (error) {
      if (error.code != 'integrity_failed' ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        rethrow;
      }
      await file.delete();
    }
    final partial = File('${file.path}.${_nonce()}.part');
    RandomAccessFile? handle;
    try {
      handle = await partial.open(mode: FileMode.writeOnly);
      var received = 0;
      await _transport.fetch(
        manifest.url,
        maxBytes: manifest.sizeBytes,
        timeout: const Duration(minutes: 20),
        onChunk: (chunk) async {
          _active();
          received += chunk.length;
          if (received > manifest.sizeBytes) _fail('integrity_failed');
          await handle!.writeFrom(chunk);
          onProgress(
            FullUpdateProgress(received: received, total: manifest.sizeBytes),
          );
        },
      );
      _active();
      await handle.flush();
      await handle.close();
      handle = null;
      if (!await _validFile(partial, manifest)) _fail('integrity_failed');
      _active();
      await partial.rename(file.path);
      return manifest.offer;
    } finally {
      await handle?.close();
      if (await partial.exists()) await partial.delete();
    }
  });
  @override
  Future<FullUpdateHandoff> handoff(FullUpdateOffer offer) =>
      _exclusive(() async {
        final manifest = _offer(offer), context = await _context();
        if (!manifest.newerThan(context)) _fail('update_incompatible');
        try {
          if (!await _validFile(
            File('${context.cacheDirectory.path}/${manifest.sha256}.apk'),
            manifest,
          )) {
            throw AppUpdatesFailure('update_not_ready', retryDownload: true);
          }
        } on AppUpdatesFailure catch (error) {
          throw AppUpdatesFailure(error.code, retryDownload: true);
        }
        Object? result;
        try {
          result = await _native('install', {
            'version': manifest.version,
            'build': manifest.build,
            'sha256': manifest.sha256,
          });
        } on AppUpdatesFailure catch (error) {
          throw AppUpdatesFailure(
            error.code,
            retryDownload: error.code == 'integrity_failed',
          );
        }
        if (result != 'installerOpened') _fail('invalid_response');
        return FullUpdateHandoff.installerOpened;
      });
  @override
  Future<void> restartUi() async => _fail('unsupported_platform');
  @override
  Future<void> cancel() async {
    _cancelled = true;
    _transport.cancel();
    await _stopped;
    if (!_disposed) _cancelled = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _transport.cancel();
  }
}
