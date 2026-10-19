// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'android_full_updates.dart';
import 'independent_ota_catalog.dart';

typedef IndependentOtaFetch = Future<Uint8List> Function(Uri uri, int limit);

/// The pinned native client's ureq serializes requests with pretty JSON. This
/// wire format is separate from the canonical signed catalog representation.
@visibleForTesting
Map<String, dynamic> decodeIndependentOtaWireRequest(List<int> bytes) {
  const limit = 16 * 1024;
  if (bytes.isEmpty || bytes.length > limit) {
    throw const IndependentOtaFailure('request_invalid');
  }
  try {
    // Validate before removing whitespace: malformed tokens such as `1 2`
    // must never be repaired into a valid number by normalization.
    final original = jsonDecode(utf8.decode(bytes));
    if (original is! Map<String, dynamic>) {
      throw const IndependentOtaFailure('request_invalid');
    }
    final compact = <int>[];
    var inString = false;
    var escaped = false;
    for (final byte in bytes) {
      if (inString) {
        compact.add(byte);
        if (escaped) {
          escaped = false;
        } else if (byte == 0x5c) {
          escaped = true;
        } else if (byte == 0x22) {
          inString = false;
        }
      } else if (byte == 0x22) {
        inString = true;
        compact.add(byte);
      } else if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
        compact.add(byte);
      }
    }
    // Preserve canonical values and duplicate-key rejection after accepting
    // only insignificant JSON whitespace outside strings.
    return decodeIndependentOtaJson(compact, limit);
  } on IndependentOtaFailure {
    rethrow;
  } catch (_) {
    throw const IndependentOtaFailure('request_invalid');
  }
}

Future<Uint8List> fetchIndependentOtaBytes(Uri uri, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await AndroidHttpsUpdateTransport().fetch(
    uri,
    maxBytes: limit,
    timeout: limit <= independentOtaMaxCatalog
        ? const Duration(seconds: 25)
        : const Duration(minutes: 3),
    onChunk: (chunk) async {
      bytes.add(chunk);
    },
  );
  return bytes.takeBytes();
}

/// Only authenticated public catalogs are stored here, never signing keys,
/// subscriptions, raw updater requests or client identifiers.
class IndependentOtaStore {
  IndependentOtaStore(this.directory);
  final Directory directory;

  Future<List<Uint8List>> read() async {
    if (!await directory.exists()) return [];
    if (await FileSystemEntity.isLink(directory.path)) {
      throw const IndependentOtaFailure('catalog_storage_failed');
    }
    final files = <File>[];
    await for (final item in directory.list(followLinks: false)) {
      if (RegExp(r'catalog-[1-9][0-9]{0,9}\.json$')
          .hasMatch(item.uri.pathSegments.last)) {
        if (item is! File ||
            files.length >= 64 ||
            await item.length() > independentOtaMaxCatalog) {
          throw const IndependentOtaFailure('catalog_storage_failed');
        }
        files.add(item);
      }
    }
    final values = <Uint8List>[];
    for (final file in files) {
      values.add(await file.readAsBytes());
    }
    return values;
  }

  /// Flush an ignored temporary record before an atomic rename. Interrupted
  /// writes cannot erase the old high-water mark or poison future retries.
  Future<void> append(IndependentOtaCatalog catalog) async {
    await directory.create(recursive: true);
    if (await FileSystemEntity.isLink(directory.path)) {
      throw const IndependentOtaFailure('catalog_storage_failed');
    }
    final target = File('${directory.path}/catalog-${catalog.revision}.json');
    if (await target.exists()) {
      if (await FileSystemEntity.isLink(target.path) ||
          !listEquals(await target.readAsBytes(), catalog.envelope)) {
        throw const IndependentOtaFailure('catalog_replayed');
      }
      return;
    }
    final nonce = base64UrlEncode(
      List.generate(18, (_) => Random.secure().nextInt(256)),
    );
    final temporary = File(
      '${directory.path}/.catalog-${catalog.revision}-$nonce.tmp',
    );
    await temporary.create(exclusive: true);
    try {
      final file = await temporary.open(mode: FileMode.writeOnly);
      try {
        await file.writeFrom(catalog.envelope);
        await file.flush();
      } finally {
        await file.close();
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    // Keep several independently signed predecessors for high-water recovery.
    final existing = <File>[];
    await for (final item in directory.list(followLinks: false)) {
      if (item is File &&
          RegExp(r'catalog-[1-9][0-9]{0,9}\.json$')
              .hasMatch(item.uri.pathSegments.last)) {
        existing.add(item);
      }
    }
    existing.sort((a, b) {
      int revision(File f) => int.parse(
        RegExp(r'catalog-(\d+)\.json$').firstMatch(f.path)!.group(1)!,
      );
      return revision(b).compareTo(revision(a));
    });
    for (final stale in existing.skip(8)) {
      await stale.delete();
    }
  }
}

/// One process-owned protocol adapter for the pinned open-source native SDK.
/// The listener is deliberately NEVER released by a production timeout or
/// widget disposal: an outstanding blocking FFI call may still address it.
class IndependentOtaBridge {
  IndependentOtaBridge({
    required this.version,
    required this.compatibility,
    required this.target,
    this.port = independentOtaPort,
    IndependentOtaFetch? fetch,
    Future<IndependentOtaStore> Function()? store,
    DateTime Function()? now,
    this.publicKey,
  }) : _fetch = fetch ?? fetchIndependentOtaBytes,
       _storeFactory = store ?? _defaultStore,
       _now = now ?? DateTime.now;

  static IndependentOtaBridge? _process;
  static IndependentOtaBridge forProcess(
    String version,
    String compatibility,
    String target,
  ) => _process ??= IndependentOtaBridge(
    version: version,
    compatibility: compatibility,
    target: target,
  );
  final String version, compatibility, target;
  final int port;
  final List<int>? publicKey;
  final IndependentOtaFetch _fetch;
  final Future<IndependentOtaStore> Function() _storeFactory;
  final DateTime Function() _now;
  HttpServer? _server;
  Future<void>? _starting;
  IndependentOtaBase? _base;
  IndependentOtaCatalog? _catalog;
  Uint8List? _diff;
  String? _diffHash;
  String? _track;
  bool _disabled = false;
  int _requests = 0;
  static Future<IndependentOtaStore> _defaultStore() async {
    final support = await getApplicationSupportDirectory();
    return IndependentOtaStore(Directory('${support.path}/independent-ota-v1'));
  }

  int get boundPort => _server?.port ?? 0;
  bool get disabled => _disabled;

  Future<void> start() => _starting ??= _bind();
  Future<void> _bind() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      _server!.idleTimeout = const Duration(seconds: 5);
      _server!.listen(
        (request) {
          unawaited(_serve(request));
        },
        onError: (Object _) {
          disable();
        },
      );
    } catch (_) {
      _disabled = true;
      throw const IndependentOtaFailure('adapter_unavailable');
    }
  }

  void disable() {
    _disabled = true;
    _base = null;
    _diff = null;
    _diffHash = null;
    // Keep _server bound until process destruction.
  }

  Future<void> prepare(String track, {required bool download}) async {
    if (_disabled) throw const IndependentOtaFailure('adapter_unavailable');
    _base = null;
    _diff = null;
    _diffHash = null;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(compatibility)) {
      throw const IndependentOtaFailure('base_incompatible');
    }
    await start();
    final bytes = await _fetch(
      Uri.parse(independentOtaFeed),
      independentOtaMaxCatalog,
    );
    final catalog = await IndependentOtaCatalog.verify(
      bytes,
      now: _now().toUtc(),
      track: track,
      publicKey: publicKey,
    );
    final store = await _storeFactory();
    IndependentOtaCatalog? previous;
    for (final record in await store.read()) {
      final old = await IndependentOtaCatalog.verify(
        record,
        now: _now().toUtc(),
        track: track,
        allowExpired: true,
        publicKey: publicKey,
      );
      if (previous == null || old.revision > previous.revision) {
        previous = old;
      } else if (old.revision == previous.revision) {
        old.requireSuccessorOf(previous);
      }
    }
    if (previous != null) catalog.requireSuccessorOf(previous);
    final base = catalog.base(version, compatibility);
    if (base == null) throw const IndependentOtaFailure('base_incompatible');
    // Publish permission only after durable authenticated metadata.
    await store.append(catalog);
    _catalog = catalog;
    _base = base;
    _track = track;
    _diff = null;
    _diffHash = null;
    if (download) {
      // Exactly the process ABI; another local client cannot change it.
      final patch = base.patches.where((p) => p.target == target).firstOrNull;
      if (patch != null) {
        final diff = await _fetch(patch.url, patch.sizeBytes);
        if (diff.length != patch.sizeBytes ||
            hashes.sha256.convert(diff).toString() != patch.sha256) {
          throw const IndependentOtaFailure('patch_integrity_failed');
        }
        _diff = diff;
        _diffHash = patch.sha256;
      }
    }
  }

  Future<void> _serve(HttpRequest request) async {
    _requests++;
    try {
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (_requests > 8 ||
          request.uri.hasQuery ||
          request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:$boundPort') {
        request.response.statusCode = HttpStatus.badRequest;
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/v1/patches/events') {
        // Discard metadata without logging/forwarding client_id or raw events.
        await _body(request);
        request.response.statusCode = HttpStatus.noContent;
      } else if (!_disabled &&
          request.method == 'POST' &&
          request.uri.path == '/api/v1/patches/check') {
        final query = decodeIndependentOtaWireRequest(await _body(request));
        final response = responseFor(query);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      } else if (!_disabled &&
          request.method == 'GET' &&
          _diff != null &&
          request.uri.path == '/patches/$_diffHash.patch') {
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = _diff!.length;
        request.response.add(_diff!);
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      }
      await request.response.close().timeout(const Duration(seconds: 10));
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
      try {
        await request.response.close();
      } catch (_) {
        /* no raw logs */
      }
    } finally {
      _requests--;
    }
  }

  Future<Uint8List> _body(HttpRequest request) async {
    if (request.contentLength > 16 * 1024) {
      throw const IndependentOtaFailure('request_invalid');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > 16 * 1024) {
        throw const IndependentOtaFailure('request_invalid');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @visibleForTesting
  Map<String, Object?> responseFor(Map<String, dynamic> query) {
    const fields = {
      'app_id',
      'channel',
      'release_version',
      'platform',
      'arch',
      'client_id',
      'current_patch_number',
    };
    if (_disabled ||
        _base == null ||
        _catalog == null ||
        !_catalog!.expiresAt.isAfter(_now().toUtc()) ||
        query.keys.any((k) => !fields.contains(k)) ||
        !query.keys.toSet().containsAll(
          fields.difference({'current_patch_number'}),
        ) ||
        query['app_id'] != independentOtaAppId ||
        query['channel'] != _track ||
        query['release_version'] != version ||
        query['client_id'] is! String ||
        (query['client_id'] as String).length > 128 ||
        (query.containsKey('current_patch_number') &&
            (query['current_patch_number'] is! int ||
                query['current_patch_number'] <= 0 ||
                query['current_patch_number'] > 2147483647))) {
      throw const IndependentOtaFailure('request_invalid');
    }
    if ('${query['platform']}/${query['arch']}' != target) {
      throw const IndependentOtaFailure('request_invalid');
    }
    final patch = _base!.patch(query['platform'], query['arch']);
    final current = query['current_patch_number'] as int?;
    return {
      'patch_available':
          patch != null && (current == null || patch.number > current),
      'patch': patch == null
          ? null
          : {
              'number': patch.number,
              'download_url':
                  'http://127.0.0.1:$boundPort/patches/${patch.sha256}.patch',
              'hash': patch.aotSha256,
              'hash_signature': patch.signature,
            },
      'rolled_back_patch_numbers': _base!.revoked.toList()..sort(),
    };
  }

  @visibleForTesting
  Future<void> closeForTests() async {
    await _server?.close(force: true);
  }
}
