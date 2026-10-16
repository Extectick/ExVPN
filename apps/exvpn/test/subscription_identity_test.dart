import 'dart:convert';

import 'package:exvpn/services/subscription_identity.dart';
import 'package:exvpn/services/secure_key_value.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Store implements SecureKeyValueStore {
  String? value;
  int writes = 0;
  bool unavailable = false;
  bool losesWrite = false;
  @override
  Future<String?> read(String key) async {
    expect(key, SubscriptionIdentity.storageKey);
    if (unavailable) throw StateError('private backend detail');
    return value;
  }

  @override
  Future<void> write(String key, String data) async {
    writes++;
    if (!losesWrite) value = data;
  }

  @override
  Future<void> delete(String key) async => fail('must not delete identity');
}

void main() {
  final first = Uri.parse('https://provider.example/sub/first-token');
  test(
    'parallel requests create one persistent identity per installation',
    () async {
      final store = _Store();
      final identity = SubscriptionIdentity.forTesting(store);
      final values = await Future.wait(
        List.generate(5, (_) => identity.forProvider(first)),
      );
      expect(values.toSet(), hasLength(1));
      expect(store.writes, 1);
      expect(values.first, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(values.first, isNot(store.value));
      expect(
        await SubscriptionIdentity.forTesting(store).forProvider(first),
        values.first,
      );
    },
  );

  test(
    'tokens do not affect identity; separate origins cannot correlate it',
    () async {
      final store = _Store();
      final identity = SubscriptionIdentity.forTesting(store);
      final value = await identity.forProvider(first);
      expect(
        await identity.forProvider(
          Uri.parse('https://PROVIDER.example:443/rotated-token'),
        ),
        value,
      );
      expect(
        await identity.forProvider(
          Uri.parse('https://other.example/sub/first-token'),
        ),
        isNot(value),
      );
      expect(
        await identity.forProvider(
          Uri.parse('https://provider.example:8443/sub/first-token'),
        ),
        isNot(value),
      );
      expect(
        await SubscriptionIdentity.forTesting(_Store()).forProvider(first),
        isNot(value),
      );
    },
  );

  for (final broken in ['invalid', base64Url.encode(List.filled(31, 0))]) {
    test(
      'damaged identity is retained without silent rotation (${broken.length})',
      () async {
        final store = _Store()..value = broken;
        final identity = SubscriptionIdentity.forTesting(store);
        await expectLater(identity.forProvider(first), throwsStateError);
        await expectLater(identity.forProvider(first), throwsStateError);
        expect(store.writes, 0);
        expect(store.value, broken);
      },
    );
  }
  test('failed read and unconfirmed write never produce an identity', () async {
    final unreadable = _Store()..unavailable = true;
    await expectLater(
      SubscriptionIdentity.forTesting(unreadable).forProvider(first),
      throwsStateError,
    );
    expect(unreadable.writes, 0);
    final losesWrite = _Store()..losesWrite = true;
    await expectLater(
      SubscriptionIdentity.forTesting(losesWrite).forProvider(first),
      throwsStateError,
    );
    expect(losesWrite.value, isNull);
  });
  test('unsafe origins do not open storage', () async {
    final store = _Store();
    final identity = SubscriptionIdentity.forTesting(store);
    for (final uri in [
      'http://provider.example',
      'https://user:password@provider.example',
      'file:///tmp',
    ]) {
      await expectLater(identity.forProvider(Uri.parse(uri)), throwsStateError);
    }
    expect(store.writes, 0);
  });
}
