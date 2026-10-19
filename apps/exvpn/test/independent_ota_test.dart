// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exvpn/services/dart_updates_independent.dart';
import 'package:exvpn/services/dart_updates_types.dart';
import 'package:exvpn/services/independent_ota_bridge.dart';
import 'package:exvpn/services/independent_ota_catalog.dart';

const version = '0.1.10+31';
final compatibility = 'a' * 64;
final clock = DateTime.utc(2026, 10, 20);
final diff = Uint8List.fromList([1, 2, 3, 4]);
late SimpleKeyPair key;
late List<int> publicKey;

Map<String, dynamic> patch({int number = 1}) => {
  'platform': 'windows',
  'arch': 'x86_64',
  'number': number,
  'url': 'https://github.com/Extectick/ExVPN/releases/download/ota-fixture/code.patch',
  'sha256': hashes.sha256.convert(diff).toString(),
  'sizeBytes': diff.length,
  'aotSha256': 'b' * 64,
  'signature': base64Encode(List.filled(512, 1)),
};
Map<String, dynamic> payload({
  int revision = 1,
  bool active = true,
  List<int> revoked = const [],
}) => {
  'schema': 1,
  'appId': independentOtaAppId,
  'channel': 'beta',
  'revision': revision,
  'publishedAt': '2026-10-20T00:00:00Z',
  'expiresAt': '2026-10-30T00:00:00Z',
  'bases': [
    {
      'version': version,
      'engineRevision': independentOtaEngine,
      'compatibilitySha256': compatibility,
      'patches': [if (active) patch()],
      'revoked': revoked,
    },
  ],
};
Future<Uint8List> signed(Map<String, dynamic> body) async {
  final bytes = utf8.encode(jsonEncode(body));
  final signature = await Ed25519().sign([
    ...utf8.encode(independentOtaDomain),
    ...bytes,
  ], keyPair: key);
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 1,
        'keyId': independentOtaKeyId,
        'payload': base64Encode(bytes),
        'signature': base64Encode(signature.bytes),
      }),
    ),
  );
}

Future<IndependentOtaCatalog> verify(Map<String, dynamic> body) async =>
    IndependentOtaCatalog.verify(
      await signed(body),
      now: clock,
      track: 'beta',
      publicKey: publicKey,
    );
Map<String, dynamic> query() => {
  'app_id': independentOtaAppId,
  'channel': 'beta',
  'release_version': version,
  'platform': 'windows',
  'arch': 'x86_64',
  'client_id': 'synthetic-client',
};

class Delegate implements DartUpdatesBackend {
  @override
  final track = 'beta';
  @override
  String? get disabledReason => null;
  int calls = 0;
  Completer<DartPatchSnapshot>? blocked;
  @override
  Future<DartPatchSnapshot> read() async {
    calls++;
    return blocked?.future ?? const DartPatchSnapshot(available: true);
  }

  @override
  Future<DartUpdateCheck> check() async =>
      DartUpdateCheck(DartUpdateStatus.upToDate, await read());
  @override
  Future<DartPatchSnapshot> download() => read();
}

void main() {
  setUpAll(() async {
    key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    publicKey = (await key.extractPublicKey()).bytes;
  });
  test(
    'signed catalog accepts only exact base, target and bounded artifact',
    () async {
      final catalog = await verify(payload());
      expect(
        catalog
            .base(version, compatibility)!
            .patch('windows', 'x86_64')!
            .number,
        1,
      );
      expect(catalog.base(version, 'c' * 64), isNull);
      expect(
        catalog.base(version, compatibility)!.patch('android', 'x86_64'),
        isNull,
      );
    },
  );
  test('wrong signature and wrong domain cannot authorize code', () async {
    final bytes = await signed(payload());
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    envelope['signature'] = base64Encode(List.filled(64, 0));
    await expectLater(
      IndependentOtaCatalog.verify(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        now: clock,
        track: 'beta',
        publicKey: publicKey,
      ),
      throwsA(isA<IndependentOtaFailure>()),
    );
  });
  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'expired': (b) => b['expiresAt'] = '2026-10-20T00:00:00Z',
    'future': (b) => b['publishedAt'] = '2026-10-21T00:00:00Z',
    'oversized lifetime': (b) => b['expiresAt'] = '2026-12-20T00:00:00Z',
    'wrong channel': (b) => b['channel'] = 'stable',
    'wrong app': (b) => b['appId'] = 'other',
    'wrong engine': (b) => b['bases'][0]['engineRevision'] = 'c' * 40,
    'boolean revision': (b) => b['revision'] = true,
    'duplicate revoked': (b) => b['bases'][0]['revoked'] = [2, 2],
    'active revoked': (b) => b['bases'][0]['revoked'] = [1],
    'untrusted host': (b) =>
        b['bases'][0]['patches'][0]['url'] = 'https://evil.invalid/a.patch',
    'token URL': (b) =>
        b['bases'][0]['patches'][0]['url'] += '?token=synthetic',
    'oversized diff': (b) =>
        b['bases'][0]['patches'][0]['sizeBytes'] = independentOtaMaxDiff + 1,
    'unknown platform': (b) => b['bases'][0]['patches'][0]['platform'] = 'ios',
    'extra inbound': (b) => b['inbounds'] = [],
  }.entries) {
    test('rejects ${mutation.key}', () async {
      final body = payload();
      mutation.value(body);
      await expectLater(verify(body), throwsA(isA<IndependentOtaFailure>()));
    });
  }
  test('duplicate JSON keys and alternate numeric forms rejected', () {
    for (final raw in ['{"a":1,"a":2}', '{"a":1e0}', '{ "a":1}']) {
      expect(
        () => decodeIndependentOtaJson(utf8.encode(raw), 100),
        throwsA(isA<IndependentOtaFailure>()),
      );
    }
  });
  test('replay, equivocation, base removal, code replacement and withdrawal removal rejected', () async {
    final first = await verify(payload());
    final withdrawal = await verify(
      payload(revision: 2, active: false, revoked: [1]),
    );
    withdrawal.requireSuccessorOf(first);
    expect(
      () => first.requireSuccessorOf(withdrawal),
      throwsA(isA<IndependentOtaFailure>()),
    );
    final equivocation = payload();
    equivocation['expiresAt'] = '2026-10-29T00:00:00Z';
    final equalRevision = await verify(equivocation);
    expect(
      () => equalRevision.requireSuccessorOf(first),
      throwsA(isA<IndependentOtaFailure>()),
    );
    final noBase = payload(revision: 2);
    noBase['bases'] = [];
    final removed = await verify(noBase);
    expect(
      () => removed.requireSuccessorOf(first),
      throwsA(isA<IndependentOtaFailure>()),
    );
    final replaced = payload(revision: 2);
    replaced['bases'][0]['patches'][0]['aotSha256'] = 'c' * 64;
    final changed = await verify(replaced);
    expect(
      () => changed.requireSuccessorOf(first),
      throwsA(isA<IndependentOtaFailure>()),
    );
    final missing = await verify(payload(revision: 3, active: false));
    expect(
      () => missing.requireSuccessorOf(withdrawal),
      throwsA(isA<IndependentOtaFailure>()),
    );
  });

  group('real loopback adapter', () {
    late Directory temp;
    late IndependentOtaBridge bridge;
    late Uint8List catalog;
    var tamperedDiff = false;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('exvpn-ota-fixture-');
      catalog = await signed(payload());
      tamperedDiff = false;
      bridge = IndependentOtaBridge(
        version: version,
        compatibility: compatibility,
        target: 'windows/x86_64',
        port: 0,
        publicKey: publicKey,
        now: () => clock,
        store: () async => IndependentOtaStore(temp),
        fetch: (uri, limit) async => uri.toString() == independentOtaFeed
            ? catalog
            : tamperedDiff
            ? Uint8List.fromList([9, 9, 9, 9])
            : diff,
      );
    });
    tearDown(() async {
      await bridge.closeForTests();
      await temp.delete(recursive: true);
    });
    test(
      'SDK wire check and verified diff served, unknown ABI denied',
      () async {
        await bridge.prepare('beta', download: true);
        final client = HttpClient();
        try {
          final request = await client.post(
            '127.0.0.1',
            bridge.boundPort,
            '/api/v1/patches/check',
          );
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(query()));
          final response = await request.close();
          expect(response.statusCode, 200);
          final result = jsonDecode(
            await response.transform(utf8.decoder).join(),
          );
          expect(result['patch_available'], true);
          final get = await client.getUrl(
            Uri.parse(result['patch']['download_url']),
          );
          final downloaded = await get.close();
          expect(
            await downloaded.fold<List<int>>([], (a, b) => a..addAll(b)),
            diff,
          );
          expect(
            () => bridge.responseFor(query()..['arch'] = 'aarch64'),
            throwsA(isA<IndependentOtaFailure>()),
          );
          expect(
            bridge.responseFor(
              query()..['current_patch_number'] = 1,
            )['patch_available'],
            false,
          );
        } finally {
          client.close(force: true);
        }
      },
    );
    test('tampered diff never handed to native updater', () async {
      tamperedDiff = true;
      await expectLater(
        bridge.prepare('beta', download: true),
        throwsA(isA<IndependentOtaFailure>()),
      );
      final client = HttpClient();
      try {
        final get = await client.get(
          '127.0.0.1',
          bridge.boundPort,
          '/patches/${hashes.sha256.convert(diff)}.patch',
        );
        final response = await get.close();
        expect(response.statusCode, 503);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });
    test('durable withdrawal blocks signed older feed after restart', () async {
      await bridge.prepare('beta', download: false);
      catalog = await signed(payload(revision: 2, active: false, revoked: [1]));
      await bridge.prepare('beta', download: false);
      expect(bridge.responseFor(query())['rolled_back_patch_numbers'], [1]);
      await bridge.closeForTests();
      // An independent process with the same persisted store rejects replay.
      catalog = await signed(payload());
      bridge = IndependentOtaBridge(
        version: version,
        compatibility: compatibility,
        target: 'windows/x86_64',
        port: 0,
        publicKey: publicKey,
        now: () => clock,
        store: () async => IndependentOtaStore(temp),
        fetch: (uri, limit) async => catalog,
      );
      await expectLater(
        bridge.prepare('beta', download: false),
        throwsA(isA<IndependentOtaFailure>()),
      );
    });
    test(
      'busy port fails closed; disabling does not release listener',
      () async {
        await bridge.start();
        final other = IndependentOtaBridge(
          version: version,
          compatibility: compatibility,
          target: 'windows/x86_64',
          port: bridge.boundPort,
        );
        await expectLater(other.start(), throwsA(isA<IndependentOtaFailure>()));
        bridge.disable();
        await expectLater(
          HttpServer.bind(
            InternetAddress.loopbackIPv4,
            bridge.boundPort,
            shared: false,
          ),
          throwsA(isA<SocketException>()),
        );
      },
    );
    test('FFI timeout poisons queued operations and retains port', () async {
      final delegate = Delegate()..blocked = Completer<DartPatchSnapshot>();
      final backend = IndependentDartUpdatesBackend(
        delegate,
        bridge,
        nativeTimeout: const Duration(milliseconds: 25),
      );
      await expectLater(backend.read(), throwsA(isA<DartUpdatesFailure>()));
      await expectLater(backend.check(), throwsA(isA<DartUpdatesFailure>()));
      expect(delegate.calls, 1);
      expect(bridge.disabled, true);
      await expectLater(
        HttpServer.bind(
          InternetAddress.loopbackIPv4,
          bridge.boundPort,
          shared: false,
        ),
        throwsA(isA<SocketException>()),
      );
      delegate.blocked!.complete(const DartPatchSnapshot(available: true));
    });
  });
}
