import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

import 'secure_key_value.dart';

/// Current-user DPAPI. Only ciphertext reaches files, including the temporary
/// file. Each journal key is independent and replaced by a same-volume rename.
/// One SubscriptionStore serializes access; multiple writer processes are not
/// supported by this initial implementation.
final class WindowsSecureKeyValueStore implements SecureKeyValueStore {
  WindowsSecureKeyValueStore() : _testDirectory = null;
  @visibleForTesting
  WindowsSecureKeyValueStore.forTesting(Directory directory)
    : _testDirectory = directory;

  final Directory? _testDirectory;
  Future<Directory>? _directory;
  static const _maxCiphertext = 10 * 1024 * 1024;
  // CRYPTPROTECT_UI_FORBIDDEN from the Windows SDK wincrypt.h.
  static const _cryptProtectUiForbidden = 0x1;

  Future<File> _file(String key) async {
    if (!Platform.isWindows ||
        !(RegExp(r'^exvpn_subscriptions_(current|pending)_v1$').hasMatch(key) ||
            key == 'exvpn_subscription_identity_v1')) {
      throw StateError('secure_storage_invalid_request');
    }
    final folder = await (_directory ??= () async {
      final parent = _testDirectory ?? await getApplicationSupportDirectory();
      return Directory(
        '${parent.path}${Platform.pathSeparator}secure-subscriptions',
      ).create(recursive: true);
    }());
    return File('${folder.path}${Platform.pathSeparator}$key.dpapi');
  }

  @override
  Future<String?> read(String key) async {
    final file = await _file(key);
    if (!await file.exists()) return null;
    if (await file.length() > _maxCiphertext) {
      throw StateError('secure_storage_invalid_data');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > _maxCiphertext) {
      throw StateError('secure_storage_invalid_data');
    }
    final plain = _transform(bytes, encrypt: false);
    try {
      return utf8.decode(plain);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final file = await _file(key);
    final plain = utf8.encode(value);
    if (plain.length > 8 * 1024 * 1024) {
      throw StateError('secure_storage_too_large');
    }
    late final Uint8List encrypted;
    try {
      encrypted = _transform(plain, encrypt: true);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
    final pending = File('${file.path}.tmp');
    try {
      await pending.writeAsBytes(encrypted, flush: true);
      final replaced = using(
        (arena) => MoveFileEx(
          PCWSTR(pending.path.toNativeUtf16(allocator: arena)),
          PCWSTR(file.path.toNativeUtf16(allocator: arena)),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        ).value,
      );
      if (!replaced) throw StateError('secure_storage_commit_failed');
    } finally {
      // Any interrupted-write residue is encrypted, never a plaintext backup.
      if (await pending.exists()) await pending.delete();
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = await _file(key);
    if (await file.exists()) await file.delete();
    final residue = File('${file.path}.tmp');
    if (await residue.exists()) await residue.delete();
  }

  static Uint8List _transform(Uint8List bytes, {required bool encrypt}) =>
      using((arena) {
        final input = arena<Uint8>(bytes.length);
        input.asTypedList(bytes.length).setAll(0, bytes);
        final source = arena<CRYPT_INTEGER_BLOB>()
          ..ref.cbData = bytes.length
          ..ref.pbData = input;
        final output = arena<CRYPT_INTEGER_BLOB>();
        try {
          final success = encrypt
              ? CryptProtectData(
                  source,
                  null,
                  null,
                  null,
                  _cryptProtectUiForbidden,
                  output,
                ).value
              : CryptUnprotectData(
                  source,
                  null,
                  null,
                  null,
                  _cryptProtectUiForbidden,
                  output,
                ).value;
          if (!success ||
              output.ref.pbData.address == 0 ||
              output.ref.cbData > _maxCiphertext) {
            throw StateError('secure_storage_crypto_failed');
          }
          return Uint8List.fromList(
            output.ref.pbData.asTypedList(output.ref.cbData),
          );
        } finally {
          input.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
          if (output.ref.pbData.address != 0) {
            if (!encrypt) {
              output.ref.pbData
                  .asTypedList(output.ref.cbData)
                  .fillRange(0, output.ref.cbData, 0);
            }
            LocalFree(HLOCAL(output.ref.pbData.cast()));
          }
        }
      });
}
