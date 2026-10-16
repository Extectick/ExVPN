import 'dart:convert';
import 'dart:io';

import 'package:exvpn/services/subscription_store.dart';
import 'package:exvpn/services/windows_secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('real DPAPI ciphertext reload replacement and delete', () async {
    final directory = await Directory.systemTemp.createTemp(
      'exvpn-dpapi-test-',
    );
    addTearDown(() async {
      final resolved = directory.absolute.path;
      if (!resolved.startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}exvpn-dpapi-test-',
      )) {
        throw StateError('Test cleanup escaped its temporary directory');
      }
      await directory.delete(recursive: true);
    });
    const secret = 'synthetic-test-secret-秘密';
    final backend = WindowsSecureKeyValueStore.forTesting(directory);
    await backend.write(SubscriptionStore.currentKey, secret);
    final fresh = WindowsSecureKeyValueStore.forTesting(directory);
    expect(await fresh.read(SubscriptionStore.currentKey), secret);
    final files = await directory
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(files, hasLength(1));
    expect(
      utf8.decode(await files.single.readAsBytes(), allowMalformed: true),
      isNot(contains(secret)),
    );
    await backend.write(SubscriptionStore.currentKey, 'replacement');
    expect(await fresh.read(SubscriptionStore.currentKey), 'replacement');
    // Corrupted ciphertext must fail without automatic deletion or plaintext
    // fallback. The caller can surface the error without erasing evidence.
    final original = await files.single.readAsBytes();
    final corrupted = List<int>.from(original);
    corrupted[corrupted.length - 1] ^= 1;
    await files.single.writeAsBytes(corrupted, flush: true);
    await expectLater(fresh.read(SubscriptionStore.currentKey), throwsStateError);
    expect(await files.single.readAsBytes(), corrupted);
    await files.single.writeAsBytes(original, flush: true);
    expect(await fresh.read(SubscriptionStore.currentKey), 'replacement');
    await backend.delete(SubscriptionStore.currentKey);
    expect(await fresh.read(SubscriptionStore.currentKey), isNull);
  }, skip: !Platform.isWindows);
}
