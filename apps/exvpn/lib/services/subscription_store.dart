import 'dart:async';
import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/foundation.dart';

import 'secure_backend_native.dart'
    if (dart.library.js_interop) 'secure_backend_web.dart';
import 'secure_key_value.dart';
export 'secure_key_value.dart';

enum SubscriptionStoreErrorCode {
  unsupportedPlatform,
  unavailable,
  invalidSnapshot,
  tooLarge,
  writeFailed,
}

final class SubscriptionStoreException implements Exception {
  const SubscriptionStoreException(this.code);
  final SubscriptionStoreErrorCode code;
  @override
  String toString() => 'SubscriptionStoreException(${code.name})';
}

/// One app instance owns this serial store. No raw provider payload is retained.
/// Both journal keys are protected by the OS backend. The pending record is a
/// complete new snapshot: successful deletion never leaves a historic snapshot
/// which could bring back a removed subscription.
final class SubscriptionStore {
  SubscriptionStore() : _injected = null;
  @visibleForTesting
  SubscriptionStore.forTesting(SecureKeyValueStore backend)
    : _injected = backend;

  static const maxBytes = 8 * 1024 * 1024;
  static const currentKey = 'exvpn_subscriptions_current_v1';
  static const pendingKey = 'exvpn_subscriptions_pending_v1';
  final SecureKeyValueStore? _injected;
  SecureKeyValueStore? _backend;
  Future<void> _tail = Future<void>.value();
  bool recovered = false;

  static bool get supported =>
      !kIsWeb &&
      {
        TargetPlatform.android,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);

  SecureKeyValueStore get _storage =>
      _backend ??= _injected ?? createSecureBackend();

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<AppController> load() => _serial(() async {
    recovered = false;
    _checkPlatform();
    var unreadable = false;
    var malformed = false;
    for (final key in [pendingKey, currentKey]) {
      String? raw;
      try {
        raw = await _storage.read(key);
      } catch (_) {
        unreadable = true;
        continue;
      }
      if (raw == null) continue;
      try {
        final result = _decode(raw);
        recovered = key == pendingKey || unreadable || malformed;
        return result;
      } on SubscriptionStoreException {
        malformed = true;
      }
    }
    if (unreadable) {
      throw const SubscriptionStoreException(
        SubscriptionStoreErrorCode.unavailable,
      );
    }
    if (malformed) {
      throw const SubscriptionStoreException(
        SubscriptionStoreErrorCode.invalidSnapshot,
      );
    }
    return AppController();
  });

  Future<void> save(AppController controller) {
    _checkPlatform();
    // Capture at invocation time. A queued save must never observe later edits.
    late final String raw;
    try {
      raw = jsonEncode(controller.exportSnapshot());
    } catch (_) {
      return Future.error(
        const SubscriptionStoreException(
          SubscriptionStoreErrorCode.invalidSnapshot,
        ),
      );
    }
    if (raw.length > maxBytes || utf8.encode(raw).length > maxBytes) {
      return Future.error(
        const SubscriptionStoreException(SubscriptionStoreErrorCode.tooLarge),
      );
    }
    return _serial(() async {
      try {
        await _storage.write(pendingKey, raw);
        if (await _storage.read(pendingKey) != raw) {
          throw const FormatException();
        }
        await _storage.write(currentKey, raw);
        if (await _storage.read(currentKey) != raw) {
          throw const FormatException();
        }
        await _storage.delete(pendingKey);
        if (await _storage.read(pendingKey) != null) {
          throw const FormatException();
        }
      } catch (_) {
        throw const SubscriptionStoreException(
          SubscriptionStoreErrorCode.writeFailed,
        );
      }
    });
  }

  void _checkPlatform() {
    if (_injected == null && !supported) {
      throw const SubscriptionStoreException(
        SubscriptionStoreErrorCode.unsupportedPlatform,
      );
    }
  }

  static AppController _decode(String raw) {
    try {
      if (raw.length > maxBytes || utf8.encode(raw).length > maxBytes) {
        throw const SubscriptionStoreException(
          SubscriptionStoreErrorCode.tooLarge,
        );
      }
      var depth = 0;
      var quoted = false;
      var escaped = false;
      for (final c in raw.codeUnits) {
        if (quoted) {
          if (escaped) {
            escaped = false;
          } else if (c == 92) {
            escaped = true;
          } else if (c == 34) {
            quoted = false;
          }
        } else if (c == 34) {
          quoted = true;
        } else if (c == 123 || c == 91) {
          if (++depth > 32) throw const FormatException();
        } else if (c == 125 || c == 93) {
          depth--;
        }
      }
      final snapshot = jsonDecode(raw);
      if (snapshot is! Map<String, dynamic>) throw const FormatException();
      return AppController.fromSnapshot(snapshot);
    } catch (_) {
      throw const SubscriptionStoreException(
        SubscriptionStoreErrorCode.invalidSnapshot,
      );
    }
  }
}
