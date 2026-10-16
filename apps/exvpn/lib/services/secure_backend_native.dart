import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_key_value.dart';
import 'windows_secure_store.dart';

SecureKeyValueStore createSecureBackend() {
  if (Platform.isWindows) return WindowsSecureKeyValueStore();
  if (Platform.isAndroid) return _AndroidStore();
  throw UnsupportedError('secure_storage_unsupported_platform');
}

final class _AndroidStore implements SecureKeyValueStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      migrateWithBackup: true,
      storageNamespace: 'exvpn_subscriptions_v1',
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
