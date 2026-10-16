// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:exvpn/services/data_updates_platform_native.dart';
import 'package:exvpn/services/data_updates_types.dart';
import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryTransport implements UpdateTransport {
  final bytes = <Uri, Uint8List>{};
  @override
  Future<Uint8List> get(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async =>
      bytes[uri] ?? (throw const UpdateException(UpdateError.downloadFailed));
}

void main() {
  late Directory directory;
  late KeyPair signer;
  late TrustedUpdatePolicy policy;
  late MemoryTransport transport;
  final manifest = Uri.parse('https://fixture.invalid/manifest');
  final files = Uri.parse('https://fixture.invalid/files/');
  DataUpdateClient client() => DataUpdateClient(
    policy: policy,
    context: UpdateContext(
      appVersion: '0.1.0',
      build: 1,
      channel: UpdateChannel.stable,
    ),
    store: DirectoryUpdateStore(directory),
    transport: transport,
    validateResource: (_, bytes) => parseConnectionHelp(bytes),
  );
  NativeDataUpdatesBackend backend() =>
      NativeDataUpdatesBackend('stable', () async => client());
  Future<void> publish(
    int revision,
    String text, {
    String? overrideBody,
  }) async {
    final bytes = utf8.encode(
      overrideBody ?? jsonEncode({'format': 1, 'body': text}),
    );
    final sha = hashes.sha256.convert(bytes).toString();
    final raw = utf8.encode(
      jsonEncode({
        'format': 1,
        'revision': revision,
        'channel': 'stable',
        'minVersion': '0.1.0',
        'maxVersionExclusive': '0.2.0',
        'minBuild': 1,
        'maxBuild': 100,
        'files': [
          {'path': connectionHelpPath, 'size': bytes.length, 'sha256': sha},
        ],
      }),
    );
    final signature = await Ed25519().sign(raw, keyPair: signer);
    transport.bytes[manifest] = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'keyId': 'fixture',
          'manifest': base64.encode(raw),
          'signature': base64.encode(signature.bytes),
        }),
      ),
    );
    transport.bytes[files.resolve(sha)] = Uint8List.fromList(bytes);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('exvpn-data-app-test-');
    signer = await Ed25519().newKeyPairFromSeed(
      List.filled(32, 7),
    ); // Test only.
    final key = await signer.extractPublicKey() as SimplePublicKey;
    transport = MemoryTransport();
    policy = TrustedUpdatePolicy(
      manifestUri: manifest,
      filesBaseUri: files,
      publicKeys: {'fixture': key.bytes},
      resourceLimits: {connectionHelpPath: 8192},
      requiredPaths: {connectionHelpPath},
    );
  });
  tearDown(() async {
    final resolved = await directory.resolveSymbolicLinks();
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith('$temporary${Platform.pathSeparator}') ||
        !directory.uri.pathSegments
            .where((v) => v.isNotEmpty)
            .last
            .startsWith('exvpn-data-app-test-')) {
      throw StateError('Unsafe test cleanup path');
    }
    await Directory(resolved).delete(recursive: true);
  });

  test('real signed native store stages/cancels, activates and recovers help after new instance', () async {
    await publish(1, 'Новая проверенная справка.');
    final first = backend();
    expect((await first.recover()).revision, isNull);
    expect((await first.stage()).revision, 1);
    await first.cancel();
    expect((await backend().recover()).revision, isNull);
    await first.stage();
    final active = await first.apply(() => true);
    expect(active.revision, 1);
    expect(active.help, 'Новая проверенная справка.');
    final restarted = await backend().recover();
    expect(restarted.revision, 1);
    expect(restarted.help, active.help);
  });

  test('signed malformed help cannot replace the working snapshot', () async {
    await publish(1, 'Рабочая справка.');
    final first = backend();
    await first.stage();
    await first.apply(() => true);
    await publish(
      2,
      '',
      overrideBody: '{"format":1,"body":"one","body":"two"}',
    );
    await expectLater(first.stage(), throwsA(isA<DataUpdatesFailure>()));
    expect((await backend().recover()).help, 'Рабочая справка.');
  });

  test(
    'late unsafe gate consumes stage without publication; retry can succeed',
    () async {
      await publish(1, 'Рабочая справка.');
      final first = backend();
      await first.stage();
      await expectLater(
        first.apply(() => false),
        throwsA(
          isA<DataUpdatesFailure>().having(
            (v) => v.code,
            'safe code',
            'activationDeferred',
          ),
        ),
      );
      expect((await backend().recover()).revision, isNull);
      await first.stage();
      expect((await first.apply(() => true)).revision, 1);
    },
  );

  test(
    'transient private-directory failure is safe and can be retried',
    () async {
      var attempts = 0;
      final first = NativeDataUpdatesBackend('stable', () async {
        if (++attempts == 1) throw StateError('private path should not appear');
        return client();
      });
      await expectLater(first.recover(), throwsA(isA<DataUpdatesFailure>()));
      expect((await first.recover()).revision, isNull);
      expect(attempts, 2);
    },
  );
}
