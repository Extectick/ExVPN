import 'dart:convert';

import 'package:exvpn/services/subscription_store.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter_test/flutter_test.dart';

const node =
    'vless://00000000-0000-4000-8000-000000000001@one.example.invalid:443?security=tls#One';

class MemorySecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  String? failWrite;
  bool unavailable = false;
  @override
  Future<String?> read(String key) async {
    if (unavailable) throw StateError('sensitive backend detail');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite == key) {
      values[key] = 'broken';
      throw StateError('sensitive backend detail');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  test(
    'restart restores profiles and only newest snapshot remains after deletion',
    () async {
      final backend = MemorySecureStore();
      final store = SubscriptionStore.forTesting(backend);
      final controller = AppController()
        ..addSubscription(name: 'Main', raw: node);
      await store.save(controller);
      final restarted = await SubscriptionStore.forTesting(backend).load();
      expect(restarted.groups.single.name, 'Main');
      restarted.removeSubscription(restarted.groups.single.id);
      await store.save(restarted);
      expect(
        (await SubscriptionStore.forTesting(backend).load()).groups,
        isEmpty,
      );
      expect(backend.values.keys, [SubscriptionStore.currentKey]);
      expect(
        backend.values.values.join(),
        isNot(contains('one.example.invalid')),
      );
    },
  );
  test(
    'interrupted current write recovers complete pending snapshot',
    () async {
      final backend = MemorySecureStore();
      final store = SubscriptionStore.forTesting(backend);
      final controller = AppController()
        ..addSubscription(name: 'Main', raw: node);
      await store.save(controller);
      controller.removeSubscription(controller.groups.single.id);
      backend.failWrite = SubscriptionStore.currentKey;
      await expectLater(
        store.save(controller),
        throwsA(isA<SubscriptionStoreException>()),
      );
      final restored = await SubscriptionStore.forTesting(backend).load();
      expect(restored.groups, isEmpty);
    },
  );
  test(
    'interrupted pending write preserves previous working snapshot',
    () async {
      final backend = MemorySecureStore();
      final store = SubscriptionStore.forTesting(backend);
      final controller = AppController()
        ..addSubscription(name: 'Main', raw: node);
      await store.save(controller);
      backend.failWrite = SubscriptionStore.pendingKey;
      controller.removeSubscription(controller.groups.single.id);
      await expectLater(
        store.save(controller),
        throwsA(isA<SubscriptionStoreException>()),
      );
      expect((await store.load()).groups, hasLength(1));
      expect(store.recovered, true);
    },
  );
  test(
    'concurrent saves capture invocation order and final deletion wins',
    () async {
      final backend = MemorySecureStore();
      final store = SubscriptionStore.forTesting(backend);
      final controller = AppController()
        ..addSubscription(name: 'Main', raw: node);
      final first = store.save(controller);
      controller.removeSubscription(controller.groups.single.id);
      final second = store.save(controller);
      await Future.wait([first, second]);
      expect((await store.load()).groups, isEmpty);
    },
  );
  test(
    'unavailable backend and malformed snapshots do not become empty data',
    () async {
      final backend = MemorySecureStore()..unavailable = true;
      final store = SubscriptionStore.forTesting(backend);
      await expectLater(
        store.load(),
        throwsA(
          isA<SubscriptionStoreException>().having(
            (e) => e.code,
            'code',
            SubscriptionStoreErrorCode.unavailable,
          ),
        ),
      );
      backend.unavailable = false;
      backend.values[SubscriptionStore.currentKey] = jsonEncode({
        'version': 99,
        'groups': [],
      });
      await expectLater(
        store.load(),
        throwsA(
          isA<SubscriptionStoreException>().having(
            (e) => e.code,
            'code',
            SubscriptionStoreErrorCode.invalidSnapshot,
          ),
        ),
      );
      expect(
        const SubscriptionStoreException(SubscriptionStoreErrorCode.unavailable)
            .toString(),
        isNot(contains('sensitive')),
      );
    },
  );
  test(
    'oversized or deeply nested input is rejected before constructing state',
    () async {
      final backend = MemorySecureStore();
      final store = SubscriptionStore.forTesting(backend);
      for (final value in [
        '[' * 1000 + ']' * 1000,
        'x' * (SubscriptionStore.maxBytes + 1),
      ]) {
        backend.values[SubscriptionStore.currentKey] = value;
        await expectLater(
          store.load(),
          throwsA(isA<SubscriptionStoreException>()),
        );
      }
    },
  );
}
