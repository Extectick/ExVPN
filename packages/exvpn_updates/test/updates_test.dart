// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:test/test.dart';
import 'support.dart';

void main() {
  late Fixture fixture;
  setUp(() async {
    fixture = Fixture();
    await fixture.initialize();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
    'stage is inert; activation survives a fresh client and reuses unchanged resources',
    () async {
      await fixture.install(1, '{"title":"one"}');
      await fixture.publish(2, {
        'texts/ru.json': '{"title":"one"}',
        'rules/default.dat': 'new-data',
      });
      fixture.transport.requests.clear();
      final client = fixture.client();
      final staged = await client.stage();
      expect(staged.downloadedFiles, 1);
      expect(staged.reusedFiles, 1);
      // Prepared bytes have not published a revision marker.
      final markers = await Directory(
        '${fixture.directory.path}/stable/commits',
      ).list().toList();
      expect(markers.length, 1);
      final active = await client.activate(staged);
      expect(utf8.decode(await active.read('rules/default.dat')), 'new-data');
      final loaded = await fixture.client().recover();
      expect(loaded.active!.manifest.revision, 2);
      expect(loaded.recoveredPrevious, false);
      expect(fixture.transport.requests.length, 2); // manifest + changed file
    },
  );

  test('cancel never activates and consumes the stage', () async {
    await fixture.publish(1, {'texts/ru.json': '{}'});
    final client = fixture.client();
    final staged = await client.stage();
    await expectLater(client.stage(), fails(UpdateError.busy));
    await client.cancel(staged);
    await expectLater(
      client.activate(staged),
      fails(UpdateError.stageUnavailable),
    );
    expect((await fixture.client().recover()).active, isNull);
  });

  test(
    'independent clients fail busy promptly and release on activate/cancel',
    () async {
      await fixture.publish(1, {'texts/ru.json': 'one'});
      final first = fixture.client();
      // A distinct store object and syntactically different path resolve to the
      // same directory; the lease cannot rely on client or Directory identity.
      final second = DataUpdateClient(
        policy: fixture.policy,
        context: fixture.context,
        transport: fixture.transport,
        store: DirectoryUpdateStore(Directory('${fixture.directory.path}/.')),
      );
      final staged = await first.stage();
      await expectLater(
        second.recover().timeout(const Duration(seconds: 2)),
        fails(UpdateError.busy),
      );
      await expectLater(
        second.stage().timeout(const Duration(seconds: 2)),
        fails(UpdateError.busy),
      );
      await first.activate(staged);
      expect((await second.recover()).active!.manifest.revision, 1);
      await fixture.publish(2, {'texts/ru.json': 'two'});
      final next = await second.stage();
      await expectLater(
        first.recover().timeout(const Duration(seconds: 2)),
        fails(UpdateError.busy),
      );
      await second.cancel(next);
      expect((await first.recover()).active!.manifest.revision, 1);
      final retry = await first.stage();
      await first.activate(retry);
      expect((await second.recover()).active!.manifest.revision, 2);
    },
  );

  test('stable and beta channels have independent leases', () async {
    await fixture.publish(1, {'texts/ru.json': 'one'});
    final stable = fixture.client();
    final prepared = await stable.stage();
    final beta = fixture.client(
      current: UpdateContext(
        appVersion: '0.1.2',
        build: 7,
        channel: UpdateChannel.beta,
      ),
    );
    expect((await beta.recover()).active, isNull);
    await stable.cancel(prepared);
  });

  test('a separate process writer fails busy without blocking', () async {
    final directory = await Directory(
      '${fixture.directory.path}/stable',
    ).create();
    final process = await Process.start(Platform.resolvedExecutable, [
      File('test/lock_holder.dart').absolute.path,
      '${directory.path}/writer.lock',
    ]);
    try {
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10)),
        'locked',
      );
      await expectLater(
        fixture.client().recover().timeout(const Duration(seconds: 2)),
        fails(UpdateError.busy),
      );
    } finally {
      process.stdin.writeln('release');
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    }
    expect((await fixture.client().recover()).active, isNull);
  });

  test(
    'tampered exact manifest bytes fail Ed25519 before file downloads',
    () async {
      await fixture.publish(1, {'texts/ru.json': '{}'});
      final envelope =
          jsonDecode(utf8.decode(fixture.transport.content[fixture.endpoint]!))
              as Map<String, dynamic>;
      final raw = base64.decode(envelope['manifest'] as String).toList()
        ..add(32);
      envelope['manifest'] = base64.encode(raw);
      fixture.transport.content[fixture.endpoint] = Uint8List.fromList(
        utf8.encode(jsonEncode(envelope)),
      );
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.invalidSignature),
      );
      expect(fixture.transport.requests, [fixture.endpoint]);
    },
  );

  test(
    'signed duplicate keys, wrong types and security-control fields are refused',
    () async {
      final good = jsonEncode(fixture.manifest(1, {'texts/ru.json': '{}'}));
      for (final raw in [
        good.replaceFirst('"revision":1', '"revision":1,"revision":2'),
        good.replaceFirst('"format":1', '"format":1.0'),
        good.replaceFirst('"revision":1', '"revision":"1"'),
        good.replaceFirst('{', '{"updateEndpoint":"https://other.invalid",'),
      ]) {
        final signed = await fixture.signRaw(utf8.encode(raw));
        await expectLater(
          ManifestVerifier(fixture.policy).verify(signed),
          fails(UpdateError.invalidManifest),
        );
      }
    },
  );

  test('unknown key and modified signature cannot enter staging', () async {
    await fixture.publish(1, {'texts/ru.json': '{}'});
    final envelope =
        jsonDecode(utf8.decode(fixture.transport.content[fixture.endpoint]!))
            as Map<String, dynamic>;
    envelope['keyId'] = 'provider-key';
    await expectLater(
      ManifestVerifier(
        fixture.policy,
      ).verify(utf8.encode(jsonEncode(envelope))),
      fails(UpdateError.untrustedKey),
    );
    envelope['keyId'] = 'test';
    envelope['signature'] = base64.encode(List.filled(64, 0));
    await expectLater(
      ManifestVerifier(
        fixture.policy,
      ).verify(utf8.encode(jsonEncode(envelope))),
      fails(UpdateError.invalidSignature),
    );
  });

  test(
    'path traversal, case aliases, reserved names and non-data files are refused',
    () async {
      for (final path in [
        '../texts/ru.json',
        '/texts/ru.json',
        r'texts\ru.json',
        'texts/%2e%2e.json',
        'Texts/ru.json',
        'nul.json',
        'native/core.dll',
        'code/hotfix.js',
        'other.json',
      ]) {
        await fixture.publish(1, {path: '{}'});
        await expectLater(
          fixture.client().stage(),
          fails(UpdateError.pathDenied),
        );
      }
      expect(
        await Directory(
          '${fixture.directory.path}/stable/bundles',
        ).list().isEmpty,
        true,
      );
    },
  );

  test(
    'channel, SemVer prerelease and build ranges are checked before download',
    () async {
      for (final fields in [
        <String, Object?>{'channel': 'beta'},
        {'minVersion': '0.1.3'},
        {'maxVersionExclusive': '0.1.2'},
        {'minBuild': 8},
        {'maxBuild': 6},
      ]) {
        await fixture.publish(1, {'texts/ru.json': '{}'}, fields: fields);
        await expectLater(
          fixture.client().stage(),
          fails(UpdateError.incompatible),
        );
      }
      await fixture.publish(1, {'texts/ru.json': '{}'});
      final beta = UpdateContext(
        appVersion: '0.1.0-beta.1',
        build: 7,
        channel: UpdateChannel.stable,
      );
      await expectLater(
        fixture.client(current: beta).stage(),
        fails(UpdateError.incompatible),
      );
      expect(
        AppVersion.parse(
          '1.0.0-beta.2',
        ).compareTo(AppVersion.parse('1.0.0-beta.11')),
        lessThan(0),
      );
      expect(
        AppVersion.parse(
          '1.0.0+build.1',
        ).compareTo(AppVersion.parse('1.0.0+build.2')),
        0,
      );
      expect(
        () => AppVersion.parse('1.0.0-01'),
        throwsA(isA<UpdateException>()),
      );
    },
  );

  test(
    'file hash/size mismatch and interrupted download preserve the current snapshot',
    () async {
      await fixture.install(1, 'old');
      await fixture.publish(2, {'texts/ru.json': 'new'});
      final fileUri = fixture.transport.content.keys.last;
      fixture.transport.content[fileUri] = Uint8List.fromList(
        utf8.encode('bad'),
      );
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.hashMismatch),
      );
      fixture.transport.content[fileUri] = Uint8List.fromList(
        utf8.encode('new-long'),
      );
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.hashMismatch),
      );
      fixture.transport.failAt = fileUri;
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.downloadFailed),
      );
      expect(
        utf8.decode(
          await (await fixture.client().recover()).active!.read(
            'texts/ru.json',
          ),
        ),
        'old',
      );
    },
  );

  test(
    'disk-full failures at every pre-publication boundary preserve current data',
    () async {
      await fixture.install(1, 'old');
      for (final operation in StorageOperation.values) {
        await fixture.publish(2, {'texts/ru.json': 'new'});
        final client = fixture.client(
          fault: (point) {
            if (point == operation) {
              throw const FileSystemException(
                'simulated ENOSPC',
                '',
                OSError('full', 28),
              );
            }
          },
        );
        await expectLater(() async {
          final stage = await client.stage();
          await client.activate(stage);
        }, fails(UpdateError.storageFailure));
        final recovered = await fixture.client().recover();
        expect(recovered.active!.manifest.revision, 1, reason: operation.name);
        expect(
          utf8.decode(await recovered.active!.read('texts/ru.json')),
          'old',
        );
      }
      // The sealed orphan from a failed publish is independently verified and reusable.
      await fixture.install(2, 'new');
      expect((await fixture.client().recover()).active!.manifest.revision, 2);
    },
  );

  test(
    'corrupt current payload recovers previous, but cannot lower the revision floor',
    () async {
      await fixture.install(1, 'one');
      final newest = await fixture.install(2, 'two');
      final path =
          '${fixture.directory.path}/stable/bundles/${newest.manifest.sha256}/texts/ru.json';
      await File(path).writeAsString('bad');
      final recovered = await fixture.client().recover();
      expect(recovered.active!.manifest.revision, 1);
      expect(recovered.highestRevision, 2);
      expect(recovered.recoveredPrevious, true);
      await fixture.publish(2, {'texts/ru.json': 'one'});
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.staleRevision),
      );
      await fixture.publish(
        3,
        {'texts/ru.json': 'one'},
        fields: {'rollbackOf': 1},
      );
      final client = fixture.client();
      final active = await client.activate(await client.stage());
      expect(active.manifest.revision, 3);
      expect(active.manifest.rollbackOf, 1);
      expect(utf8.decode(await active.read('texts/ru.json')), 'one');
    },
  );

  test('tampering a prepared resource prevents publication', () async {
    await fixture.install(1, 'old');
    await fixture.publish(2, {'texts/ru.json': 'new'});
    final client = fixture.client();
    final stage = await client.stage();
    final dirs = await Directory(
      '${fixture.directory.path}/stable',
    ).list().where((d) => d.path.contains('stage-')).toList();
    await File('${dirs.single.path}/texts/ru.json').writeAsString('bad');
    await expectLater(client.activate(stage), fails(UpdateError.hashMismatch));
    expect((await fixture.client().recover()).active!.manifest.revision, 1);
  });

  test(
    'host safety change during disk work defers the atomic commit',
    () async {
      await fixture.install(1, 'old');
      await fixture.publish(2, {'texts/ru.json': 'new'});
      var safe = true;
      final client = fixture.client(
        fault: (operation) {
          if (operation == StorageOperation.publishCommit) safe = false;
        },
      );
      final stage = await client.stage();
      await expectLater(
        client.activate(stage, canActivate: () => safe),
        fails(UpdateError.activationDeferred),
      );
      expect((await fixture.client().recover()).active!.manifest.revision, 1);
      // Deferred activation consumes its stage/lease; a new check can reuse the
      // sealed, independently revalidated bundle and publish safely later.
      final retry = fixture.client();
      expect(
        (await retry.activate(
          await retry.stage(),
          canActivate: () => true,
        )).manifest.revision,
        2,
      );
    },
  );

  test(
    'corrupt signed marker recovers previous and retains replay floor',
    () async {
      await fixture.install(1, 'old');
      final second = await fixture.install(2, 'new');
      await File(
        '${fixture.directory.path}/stable/commits/r2-${second.manifest.sha256}.json',
      ).writeAsString('{broken');
      final recovery = await fixture.client().recover();
      expect(recovery.active!.manifest.revision, 1);
      expect(recovery.highestRevision, 2);
      expect(recovery.recoveredPrevious, true);
      await fixture.publish(2, {'texts/ru.json': 'old'});
      await expectLater(
        fixture.client().stage(),
        fails(UpdateError.staleRevision),
      );
    },
  );

  test(
    'abandoned partial files never activate; pruning retains only current and previous',
    () async {
      await fixture.install(1, 'one');
      final abandoned = await Directory(
        '${fixture.directory.path}/stable/stage-${'a' * 32}',
      ).create();
      await File('${abandoned.path}/partial').writeAsString('incomplete');
      await File(
        '${fixture.directory.path}/stable/commits/.pending-${'b' * 64}',
      ).writeAsString('incomplete');
      expect((await fixture.client().recover()).active!.manifest.revision, 1);
      await fixture.install(2, 'two');
      expect(await abandoned.exists(), false);
      final third = await fixture.install(3, 'three');
      final commits = await Directory(
        '${fixture.directory.path}/stable/commits',
      ).list().toList();
      final bundles = await Directory(
        '${fixture.directory.path}/stable/bundles',
      ).list().toList();
      expect(commits.length, 2);
      expect(bundles.length, 2);
      await File(
        '${fixture.directory.path}/stable/bundles/${third.manifest.sha256}/texts/ru.json',
      ).writeAsString('damaged');
      expect((await fixture.client().recover()).active!.manifest.revision, 2);
    },
  );

  test('semantic validator rejection preserves current files', () async {
    await fixture.install(1, 'old');
    await fixture.publish(2, {'texts/ru.json': 'not json'});
    await expectLater(
      fixture
          .client(
            validator: (_, bytes) {
              jsonDecode(utf8.decode(bytes));
            },
          )
          .stage(),
      fails(UpdateError.invalidManifest),
    );
    expect((await fixture.client().recover()).active!.manifest.revision, 1);
  });

  test('overlarge and deeply nested manifests are bounded', () async {
    await expectLater(
      ManifestVerifier(fixture.policy).verify(List.filled(192 * 1024 + 1, 32)),
      fails(UpdateError.tooLarge),
    );
    final raw = '{"x":${'[' * 20}0${']' * 20}}';
    await expectLater(
      ManifestVerifier(
        fixture.policy,
      ).verify(await fixture.signRaw(utf8.encode(raw))),
      fails(UpdateError.invalidManifest),
    );
    await fixture.publish(1, {'texts/ru.json': 'x' * 4097});
    await expectLater(
      fixture.client().stage(),
      fails(UpdateError.invalidManifest),
    );
  });
}
