// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:test/test.dart';
import '../tool/build_data_update.dart' as authoring;

class PublishedFiles implements UpdateTransport {
  PublishedFiles(this.root);
  final Directory root;
  @override
  Future<Uint8List> get(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    final suffix = uri.path == '/manifest'
        ? 'manifest.json'
        : 'files/${uri.pathSegments.last}';
    return File('${root.path}/$suffix').readAsBytes();
  }
}

void main() {
  late Directory root, resources, output;
  late File metadata, seed, help;
  final seedBytes = List.generate(32, (i) => i + 1); // Test-only material.
  Map<String, Object> values() => {
    'keyId': 'fixture',
    'revision': 3,
    'channel': 'stable',
    'minVersion': '0.1.0',
    'maxVersionExclusive': '0.2.0',
    'minBuild': 1,
    'maxBuild': 10,
  };
  Future<void> build() => authoring.buildDataUpdate(
    resources: resources.path,
    metadata: metadata.path,
    seedFile: seed.path,
    output: output.path,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('exvpn-author-test-');
    resources = await Directory('${root.path}/resources').create();
    await Directory('${resources.path}/help').create();
    await Directory('${root.path}/.private').create();
    help = await File('${resources.path}/help/connection-ru.json')
        .writeAsString(
          jsonEncode({
            'format': 1,
            'body': 'Проверенная справка для подключения.',
          }),
        );
    metadata = await File(
      '${root.path}/metadata.json',
    ).writeAsString(jsonEncode(values()));
    seed = await File(
      '${root.path}/.private/signing.seed',
    ).writeAsBytes(seedBytes);
    output = Directory('${root.path}/revision3');
  });
  tearDown(() async {
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith('$temp${Platform.pathSeparator}') ||
        !root.uri.pathSegments
            .where((v) => v.isNotEmpty)
            .last
            .startsWith('exvpn-author-test-')) {
      throw StateError('Unsafe fixture cleanup');
    }
    await Directory(resolved).delete(recursive: true);
  });

  test(
    'offline authored package roundtrips through production verifier and actual client',
    () async {
      await build();
      final public =
          jsonDecode(
                await File('${output.path}/public-key.json').readAsString(),
              )
              as Map;
      final policy = TrustedUpdatePolicy(
        manifestUri: Uri.parse('https://offline.invalid/manifest'),
        filesBaseUri: Uri.parse('https://offline.invalid/files/'),
        publicKeys: {'fixture': base64.decode(public['publicKey'] as String)},
        resourceLimits: {'help/connection-ru.json': 8192},
        requiredPaths: {'help/connection-ru.json'},
      );
      final client = DataUpdateClient(
        policy: policy,
        context: UpdateContext(
          appVersion: '0.1.0',
          build: 1,
          channel: UpdateChannel.stable,
        ),
        store: DirectoryUpdateStore(Directory('${root.path}/consumer')),
        transport: PublishedFiles(output),
      );
      final active = await client.activate(await client.stage());
      expect(active.manifest.revision, 3);
      expect(
        await active.read('help/connection-ru.json'),
        await help.readAsBytes(),
      );
      expect((await client.recover()).active!.manifest.revision, 3);
      final files = await output
          .list(recursive: true, followLinks: false)
          .where((entry) => entry is File)
          .toList();
      expect(files.length, 3);
      for (final file in files) {
        final text = utf8.decode(await File(file.path).readAsBytes());
        expect(text, isNot(contains(base64.encode(seedBytes))));
        expect(text, isNot(contains('signing.seed')));
      }
      expect(await seed.readAsBytes(), seedBytes);
    },
  );

  test(
    'existing output and authoring reservation are never overwritten',
    () async {
      await output.create();
      final sentinel = await File(
        '${output.path}/sentinel',
      ).writeAsString('keep');
      await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
      expect(await sentinel.readAsString(), 'keep');
      await sentinel.delete();
      await output.delete();
      final lock = await File(
        '${root.path}/.revision3.authoring-lock',
      ).writeAsString('keep-lock');
      await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
      expect(await lock.readAsString(), 'keep-lock');
      expect(await output.exists(), false);
    },
  );

  test(
    'unknown resources, secret copies and malformed help are rejected before output',
    () async {
      final extra = await File(
        '${resources.path}/unexpected.dll',
      ).writeAsString('not code');
      await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
      await extra.delete();
      for (final body in [
        jsonEncode({'format': 1, 'body': base64.encode(seedBytes)}),
        '{"format":1,"body":"one","body":"two"}',
        jsonEncode({'format': 1, 'body': 'x' * 1501}),
      ]) {
        await help.writeAsString(body);
        await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
        expect(await output.exists(), false);
      }
    },
  );

  test('duplicate and invalid metadata do not produce signed output', () async {
    for (final text in [
      jsonEncode(
        values(),
      ).replaceFirst('"revision":3', '"revision":3,"revision":4'),
      jsonEncode({...values(), 'channel': 'unknown'}),
      jsonEncode({...values(), 'revision': 0}),
      jsonEncode({...values(), 'maxBuild': 0}),
      jsonEncode({...values(), 'endpoint': 'https://untrusted.invalid'}),
      jsonEncode({
        ...values(),
        'minVersion': '1.0.0',
        'maxVersionExclusive': '0.1.0',
      }),
      jsonEncode({...values(), 'rollbackOf': 3}),
    ]) {
      await metadata.writeAsString(text);
      await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
      expect(await output.exists(), false);
    }
  });

  test(
    'seed must be existing private binary file; no inline or short key accepted',
    () async {
      await seed.writeAsBytes([1, 2, 3]);
      await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
      final publicSeed = await File(
        '${root.path}/public.seed',
      ).writeAsBytes(seedBytes);
      await expectLater(
        authoring.buildDataUpdate(
          resources: resources.path,
          metadata: metadata.path,
          seedFile: publicSeed.path,
          output: output.path,
        ),
        throwsA(isA<authoring.AuthoringFailure>()),
      );
      expect(await output.exists(), false);
    },
  );

  test('symlinked resource is rejected', () async {
    await help.delete();
    final target = await File(
      '${root.path}/outside.json',
    ).writeAsString('{"format":1,"body":"text"}');
    try {
      await Link(help.path).create(target.path);
    } on FileSystemException {
      markTestSkipped(
        'Host does not permit creating symlinks; POSIX CI covers this case.',
      );
      return;
    }
    await expectLater(build(), throwsA(isA<authoring.AuthoringFailure>()));
    expect(await output.exists(), false);
    expect(await target.exists(), true);
  });

  test(
    'CLI stdout/stderr contain only safe fixed status and no signing material',
    () async {
      final script = File('tool/build_data_update.dart').absolute.path;
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=$packages',
        script,
        '--resources',
        resources.path,
        '--metadata',
        metadata.path,
        '--seed-file',
        seed.path,
        '--output',
        output.path,
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout.toString().trim(), 'package_written');
      expect(result.stderr, isEmpty);
      final failed = await Process.run(Platform.resolvedExecutable, [
        '--packages=$packages',
        script,
        '--resources',
        resources.path,
        '--metadata',
        metadata.path,
        '--seed-file',
        seed.path,
        '--output',
        output.path,
      ]);
      expect(failed.exitCode, 1);
      expect(failed.stdout, isEmpty);
      expect(
        failed.stderr.toString().trim(),
        'authoring_failed:output_exists_or_overlaps',
      );
      expect(
        '${result.stdout}${result.stderr}${failed.stdout}${failed.stderr}',
        isNot(contains(base64.encode(seedBytes))),
      );
    },
  );
}
