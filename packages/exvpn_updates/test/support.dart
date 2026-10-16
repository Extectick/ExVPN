// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:test/test.dart';

Matcher fails(UpdateError code) =>
    throwsA(isA<UpdateException>().having((e) => e.code, 'safe code', code));

final class FakeTransport implements UpdateTransport {
  final content = <Uri, Uint8List>{};
  final requests = <Uri>[];
  Uri? failAt;
  @override
  Future<Uint8List> get(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    requests.add(uri);
    if (uri == failAt || !content.containsKey(uri)) {
      throw const UpdateException(UpdateError.downloadFailed);
    }
    return Uint8List.fromList(content[uri]!);
  }
}

final class Fixture {
  late Directory directory;
  late KeyPair key;
  late TrustedUpdatePolicy policy;
  final transport = FakeTransport();
  final context = UpdateContext(
    appVersion: '0.1.2',
    build: 7,
    channel: UpdateChannel.stable,
  );
  final endpoint = Uri.parse('https://updates.invalid/stable.json');
  final filesBase = Uri.parse('https://updates.invalid/files/');

  Future<void> initialize() async {
    directory = await Directory.systemTemp.createTemp('exvpn-updates-test-');
    // Deterministic test-only seed; no production/private signing key exists.
    key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    final public = await key.extractPublicKey() as SimplePublicKey;
    policy = TrustedUpdatePolicy(
      manifestUri: endpoint,
      filesBaseUri: filesBase,
      publicKeys: {'test': public.bytes},
      resourceLimits: {'texts/ru.json': 4096, 'rules/default.dat': 4096},
      requiredPaths: {'texts/ru.json'},
    );
  }

  DataUpdateClient client({
    StorageFaultHook? fault,
    ResourceValidator? validator,
    UpdateContext? current,
  }) => DataUpdateClient(
    policy: policy,
    context: current ?? context,
    transport: transport,
    store: DirectoryUpdateStore.forTesting(directory, beforeOperation: fault),
    validateResource: validator,
  );
  Future<void> dispose() async {
    final absolute = directory.absolute.path;
    final temp = Directory.systemTemp.absolute.path;
    if (!absolute.startsWith(temp) ||
        !directory.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last
            .startsWith('exvpn-updates-test-')) {
      throw StateError('Unsafe fixture path');
    }
    await directory.delete(recursive: true);
  }

  Map<String, Object?> manifest(
    int revision,
    Map<String, String> resources, {
    Map<String, Object?> fields = const {},
  }) => {
    'format': 1,
    'revision': revision,
    'channel': 'stable',
    'minVersion': '0.1.0',
    'maxVersionExclusive': '0.2.0',
    'minBuild': 1,
    'maxBuild': 10,
    'files': [
      for (final e in resources.entries)
        {
          'path': e.key,
          'size': utf8.encode(e.value).length,
          'sha256': digest.sha256.convert(utf8.encode(e.value)).toString(),
        },
    ],
    ...fields,
  };
  Future<Uint8List> signRaw(List<int> raw) async {
    final signature = await Ed25519().sign(raw, keyPair: key);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'keyId': 'test',
          'manifest': base64.encode(raw),
          'signature': base64.encode(signature.bytes),
        }),
      ),
    );
  }

  Future<void> publish(
    int revision,
    Map<String, String> resources, {
    Map<String, Object?> fields = const {},
  }) async {
    transport.content[endpoint] = await signRaw(
      utf8.encode(jsonEncode(manifest(revision, resources, fields: fields))),
    );
    for (final value in resources.values) {
      final bytes = utf8.encode(value);
      transport.content[filesBase.resolve(
        digest.sha256.convert(bytes).toString(),
      )] = Uint8List.fromList(
        bytes,
      );
    }
  }

  Future<ActiveData> install(int revision, String text) async {
    await publish(revision, {'texts/ru.json': text});
    final app = client();
    return app.activate(await app.stage());
  }
}
