import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:exvpn/services/android_full_updates.dart';
import 'package:exvpn/services/app_updates_types.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryUpdates implements AndroidUpdateTransport {
  final objects = <Uri, List<int>>{};
  int calls = 0;
  @override
  Future<void> fetch(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
    required Future<void> Function(List<int>) onChunk,
  }) async {
    calls++;
    final bytes = objects[uri];
    if (bytes == null) throw AppUpdatesFailure('network_failed');
    for (var at = 0; at < bytes.length; at += 3) {
      await onChunk(bytes.sublist(at, (at + 3).clamp(0, bytes.length)));
    }
  }

  @override
  void cancel() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 19, 1);
  final apk = utf8.encode(
    'synthetic APK bytes independently inspected by native',
  );
  final sha = hashes.sha256.convert(apk).toString();
  late KeyPair signer;
  late List<int> publicKey;
  late Directory directory;
  late MemoryUpdates transport;
  late AndroidFullUpdatesBackend backend;
  final calls = <MethodCall>[];
  const methods = MethodChannel('test/exvpn/android-app-updates');
  Map<String, dynamic> body() => {
    'schema': 1,
    'appId': 'exvpn',
    'platform': 'android',
    'channel': 'beta',
    'version': '0.1.5',
    'build': 26,
    'publishedAt': '2026-10-19T00:00:00Z',
    'expiresAt': '2026-11-01T00:00:00Z',
    'minSdk': 30,
    'asset': {
      'url': 'https://github.com/Extectick/ExVPN/releases/download/v0.1.5/ExVPN-0.1.5-26-android.apk',
      'sizeBytes': apk.length,
      'sha256': sha,
    },
  };
  Future<Uint8List> envelope(
    Map<String, dynamic> value, {
    String? rawBody,
    String? domain,
  }) async {
    final payload = utf8.encode(rawBody ?? jsonEncode(value));
    final signature = await Ed25519().sign([
      ...utf8.encode(domain ?? androidUpdateDomain),
      ...payload,
    ], keyPair: signer);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'keyId': androidUpdateKeyId,
          'payload': base64Encode(payload),
          'signature': base64Encode(signature.bytes),
        }),
      ),
    );
  }

  Future<AndroidUpdateManifest> verify(Uint8List bytes) =>
      AndroidUpdateManifest.verify(bytes, now: now, publicKey: publicKey);
  Matcher fails(String code) => throwsA(
    isA<AppUpdatesFailure>().having((error) => error.code, 'code', code),
  );
  setUp(() async {
    signer = await Ed25519().newKeyPair();
    publicKey = (await signer.extractPublicKey() as SimplePublicKey).bytes;
    directory = await Directory.systemTemp.createTemp('exvpn-app-update-');
    directory = Directory(await directory.resolveSymbolicLinks());
    transport = MemoryUpdates();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          return 'installerOpened';
        });
    backend = AndroidFullUpdatesBackend.forTesting(
      methods: methods,
      transport: transport,
      publicKey: publicKey,
      now: () => now,
      context: () async => AndroidUpdateContext(
        version: '0.1.4',
        build: 25,
        sdk: 30,
        cacheDirectory: directory,
      ),
    );
    final value = body();
    transport.objects[Uri.parse(androidUpdateFeed)] = await envelope(value);
    transport.objects[Uri.parse((value['asset'] as Map)['url'] as String)] =
        apk;
  });
  tearDown(() async {
    backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    await directory.delete(recursive: true);
  });
  test('production feed/key exactly match committed public pins', () async {
    final config = jsonDecode(
      await File('../../config/updates/android-beta.json').readAsString(),
    );
    expect(config['feedUrl'], androidUpdateFeed);
    expect(config['keyId'], androidUpdateKeyId);
    expect(config['publicKey'], androidUpdatePublicKey);
  });
  test(
    'valid signed offer requires newer build and never semantic downgrade',
    () async {
      final manifest = await verify(await envelope(body()));
      expect(manifest.identity, '0.1.5+26');
      expect(
        manifest.newerThan(
          AndroidUpdateContext(
            version: '0.1.4',
            build: 25,
            sdk: 30,
            cacheDirectory: directory,
          ),
        ),
        true,
      );
      expect(
        manifest.newerThan(
          AndroidUpdateContext(
            version: '0.1.5',
            build: 26,
            sdk: 30,
            cacheDirectory: directory,
          ),
        ),
        false,
      );
      expect(
        manifest.newerThan(
          AndroidUpdateContext(
            version: '0.2.0',
            build: 1,
            sdk: 30,
            cacheDirectory: directory,
          ),
        ),
        false,
      );
    },
  );
  test('cross-platform signature domain and wrong platform rejected', () async {
    await expectLater(
      verify(await envelope(body(), domain: 'ExVPN/windows-update/v1\x00')),
      fails('signature_invalid'),
    );
    await expectLater(
      verify(await envelope(body()..['platform'] = 'windows-x64')),
      fails('manifest_invalid'),
    );
  });
  test('tamper and duplicate payload/envelope fields rejected', () async {
    final raw =
        jsonDecode(utf8.decode(await envelope(body()))) as Map<String, dynamic>;
    raw['payload'] = base64Encode(
      utf8.encode(jsonEncode(body()..['build'] = 27)),
    );
    await expectLater(
      verify(Uint8List.fromList(utf8.encode(jsonEncode(raw)))),
      fails('signature_invalid'),
    );
    final duplicated = jsonEncode(body())
        .replaceFirst('"schema":1', '"schema":1,"schema":1');
    await expectLater(
      verify(await envelope(body(), rawBody: duplicated)),
      fails('manifest_invalid'),
    );
    final outer = utf8
        .decode(await envelope(body()))
        .replaceFirst('"schema":1', '"schema":1,"schema":1');
    await expectLater(
      verify(Uint8List.fromList(utf8.encode(outer))),
      fails('manifest_invalid'),
    );
  });
  test(
    'wrong field types, unknown fields and noncanonical base64 rejected',
    () async {
      for (final bad in [
        body()..['build'] = '26',
        body()..['minSdk'] = 30.5,
        body()..['schema'] = 1.0,
        body()..['extra'] = true,
        body()..['version'] = '0.1.5\n',
      ]) {
        await expectLater(
          verify(await envelope(bad)),
          fails('manifest_invalid'),
        );
      }
      final hashNewline = body();
      (hashNewline['asset'] as Map)['sha256'] = '$sha\n';
      await expectLater(
        verify(await envelope(hashNewline)),
        fails('manifest_invalid'),
      );
      final outer = jsonDecode(
        utf8.decode(await envelope(body())),
      ) as Map<String, dynamic>;
      outer['signature'] = '${outer['signature']}\n';
      await expectLater(
        verify(Uint8List.fromList(utf8.encode(jsonEncode(outer)))),
        fails('manifest_invalid'),
      );
    },
  );
  test(
    'expiry, future dates, impossible date and validity over30days rejected',
    () async {
      await expectLater(
        verify(await envelope(body()..['expiresAt'] = '2026-10-19T01:00:00Z')),
        fails('update_expired'),
      );
      for (final bad in [
        body()..['publishedAt'] = '2026-10-20T00:00:00Z',
        body()..['expiresAt'] = '2027-01-01T00:00:00Z',
        body()..['publishedAt'] = '2026-02-30T00:00:00Z',
      ]) {
        await expectLater(
          verify(await envelope(bad)),
          fails('manifest_invalid'),
        );
      }
    },
  );
  test(
    'exact immutable repository APK URL and bounded byte size required',
    () async {
      for (final field in [
        'http://github.com/Extectick/ExVPN/releases/download/v0.1.5/file.apk',
        'https://github.com/other/repo/releases/download/v0.1.5/file.apk',
        'https://127.0.0.1/file.apk',
      ]) {
        final value = body();
        (value['asset'] as Map)['url'] = field;
        await expectLater(
          verify(await envelope(value)),
          fails('manifest_invalid'),
        );
      }
      for (final size in [0, -1, androidUpdateMaxApkBytes + 1, '4']) {
        final value = body();
        (value['asset'] as Map)['sizeBytes'] = size;
        await expectLater(
          verify(await envelope(value)),
          fails('manifest_invalid'),
        );
      }
    },
  );
  test(
    'redirect policy rejects credentials cleartext foreign repo and localhosts',
    () {
      final initial = Uri.parse(androidUpdateFeed);
      for (final uri in [
        'http://release-assets.githubusercontent.com/a',
        'https://user@release-assets.githubusercontent.com/a',
        'https://github.com/other/repo/file',
        'https://127.0.0.1/a',
        'https://objects.githubusercontent.com:444/a',
        'https://objects.githubusercontent.com/arbitrary/file.apk',
        'https://release-assets.githubusercontent.com/github-production-release-asset/%2e%2e/elsewhere',
        'https://objects.githubusercontent.com/github-production-release-asset/%2foutside',
        'https://api.github.com/repos/Other/ExVPN/releases/assets/42',
        'https://api.github.com/repos/Extectick/ExVPN/releases/assets/0',
      ]) {
        expect(
          AndroidHttpsUpdateTransport.allowedRedirect(Uri.parse(uri), initial),
          false,
        );
      }
      expect(
        AndroidHttpsUpdateTransport.allowedRedirect(
          Uri.parse(
            'https://release-assets.githubusercontent.com/github-production-release-asset/42/file.apk?fixture=value',
          ),
          initial,
        ),
        true,
      );
      for (final url in [
        'https://objects.githubusercontent.com/github-production-release-asset-2e65be/42/file.apk',
        'https://github-releases.githubusercontent.com/github-production-release-asset/42/file.apk',
        'https://api.github.com/repos/Extectick/ExVPN/releases/assets/42',
      ]) {
        expect(
          AndroidHttpsUpdateTransport.allowedRedirect(Uri.parse(url), initial),
          true,
        );
      }
    },
  );
  test('HTTPS production context explicitly requires TLS1.2 or later', () {
    expect(
      AndroidHttpsUpdateTransport.secureContext().minimumTlsProtocolVersion,
      TlsProtocolVersion.tls1_2,
    );
  });
  test(
    'atomic verified download and install request never forward path URL key',
    () async {
      final offer = (await backend.check())!;
      final progress = <int>[];
      await backend.download(
        offer,
        onProgress: (value) => progress.add(value.received),
      );
      expect(progress.last, apk.length);
      expect(await File('${directory.path}/$sha.apk').readAsBytes(), apk);
      expect(
        directory.listSync().where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
      expect(await backend.handoff(offer), FullUpdateHandoff.installerOpened);
      expect(calls.single.method, 'install');
      expect(calls.single.arguments, {
        'version': '0.1.5',
        'build': 26,
        'sha256': sha,
      });
      final before = transport.calls;
      await backend.download(offer, onProgress: (_) {});
      expect(transport.calls, before);
    },
  );
  test(
    'bad hash short and oversized transfers never produce prepared APK',
    () async {
      final offer = (await backend.check())!;
      final url = Uri.parse((body()['asset'] as Map)['url'] as String);
      for (final bytes in [
        apk.sublist(1),
        [...apk, 0],
        List<int>.filled(apk.length, 0),
      ]) {
        transport.objects[url] = bytes;
        await expectLater(
          backend.download(offer, onProgress: (_) {}),
          fails('integrity_failed'),
        );
      }
      expect(await File('${directory.path}/$sha.apk').exists(), false);
    },
  );
  test(
    'missing corrupt prepared cache requests redownload and repair rechecks',
    () async {
      final offer = (await backend.check())!;
      await expectLater(
        backend.handoff(offer),
        throwsA(
          isA<AppUpdatesFailure>().having(
            (error) => error.retryDownload,
            'retry download',
            true,
          ),
        ),
      );
      await backend.download(offer, onProgress: (_) {});
      await File('${directory.path}/$sha.apk').writeAsString('bad');
      await expectLater(
        backend.handoff(offer),
        throwsA(
          isA<AppUpdatesFailure>().having(
            (error) => error.retryDownload,
            'retry download',
            true,
          ),
        ),
      );
      await backend.download(offer, onProgress: (_) {});
      expect(await backend.handoff(offer), FullUpdateHandoff.installerOpened);
    },
  );
  test('permission failure retains ready cache and explicit retry does not redownload', () async {
    final offer = (await backend.check())!;
    await backend.download(offer, onProgress: (_) {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          methods,
          (_) async =>
              throw PlatformException(code: 'install_permission_required'),
        );
    await expectLater(
      backend.handoff(offer),
      fails('install_permission_required'),
    );
    final before = transport.calls;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (_) async => 'installerOpened');
    expect(await backend.handoff(offer), FullUpdateHandoff.installerOpened);
    expect(transport.calls, before);
  });
  test(
    'signed replay to lower seen build rejected and prior receipt preserved',
    () async {
      await backend.check();
      final original = await File('${directory.path}/offer.json').readAsBytes();
      final old = body()
        ..['version'] = '0.1.4'
        ..['build'] = 25;
      (old['asset'] as Map)['url'] = 'https://github.com/Extectick/ExVPN/releases/download/v0.1.4/ExVPN-0.1.4-25-android.apk';
      transport.objects[Uri.parse(androidUpdateFeed)] = await envelope(old);
      await expectLater(backend.check(), fails('manifest_invalid'));
      expect(
        await File('${directory.path}/offer.json').readAsBytes(),
        original,
      );
    },
  );
}
