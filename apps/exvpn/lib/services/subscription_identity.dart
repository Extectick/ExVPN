import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'secure_backend_native.dart'
    if (dart.library.js_interop) 'secure_backend_web.dart';
import 'secure_key_value.dart';

/// Installation identity, never a hardware serial or an account credential.
/// Each HTTPS origin receives a different stable HMAC. A broken store must not
/// silently rotate the identity and consume additional provider device slots.
final class SubscriptionIdentity {
  SubscriptionIdentity() : _backend = null;
  SubscriptionIdentity.forTesting(this._backend);

  static final instance = SubscriptionIdentity();
  static const storageKey = 'exvpn_subscription_identity_v1';
  SecureKeyValueStore? _backend;
  Future<List<int>>? _secret;

  Future<String> forProvider(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw StateError('subscription_identity_invalid_origin');
    }
    final secret = await (_secret ??= _load());
    final origin = 'https://${uri.host.toLowerCase()}:${uri.port}';
    return Hmac(sha256, secret).convert(utf8.encode(origin)).toString();
  }

  Future<List<int>> _load() async {
    try {
      final backend = _backend ??= createSecureBackend();
      var stored = await backend.read(storageKey);
      if (stored == null) {
        final random = Random.secure();
        final bytes = List<int>.generate(32, (_) => random.nextInt(256));
        stored = base64Url.encode(bytes);
        await backend.write(storageKey, stored);
        if (await backend.read(storageKey) != stored) {
          throw const FormatException();
        }
      }
      final bytes = base64Url.decode(stored);
      if (bytes.length != 32 || base64Url.encode(bytes) != stored) {
        throw const FormatException();
      }
      return List<int>.unmodifiable(bytes);
    } catch (_) {
      throw StateError('subscription_identity_unavailable');
    }
  }
}
