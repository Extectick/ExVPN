// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:exvpn_updates/exvpn_updates.dart';
// Reuse the exact current application schema; this source has no Flutter import.
// Repository-local authoring intentionally shares the app's pure Dart schema.
// ignore: avoid_relative_lib_imports
import '../../../apps/exvpn/lib/services/data_updates_types.dart'
    show connectionHelpPath, parseConnectionHelp;

final class AuthoringFailure implements Exception {
  const AuthoringFailure(this.code);
  final String code;
  @override
  String toString() => 'AuthoringFailure($code)';
}

Never _reject(String code) => throw AuthoringFailure(code);

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length == 1 && arguments.single == '--help') {
      stdout.writeln(
        'Usage: dart run tool/build_data_update.dart --resources DIR '
        '--metadata FILE --seed-file ABSOLUTE_PRIVATE_FILE --output NEW_DIR',
      );
      stdout.writeln(
        'Offline only. Existing 32-byte binary seed under .private; no key generation or upload.',
      );
      return;
    }
    if (arguments.length != 8) _reject('usage');
    final options = <String, String>{};
    const names = {'--resources', '--metadata', '--seed-file', '--output'};
    for (var index = 0; index < arguments.length; index += 2) {
      if (!names.contains(arguments[index]) ||
          options.containsKey(arguments[index]) ||
          arguments[index + 1].isEmpty) {
        _reject('usage');
      }
      options[arguments[index]] = arguments[index + 1];
    }
    await buildDataUpdate(
      resources: options['--resources']!,
      metadata: options['--metadata']!,
      seedFile: options['--seed-file']!,
      output: options['--output']!,
    );
    stdout.writeln('package_written');
  } on AuthoringFailure catch (error) {
    stderr.writeln('authoring_failed:${error.code}');
    exitCode = 1;
  } catch (_) {
    stderr.writeln('authoring_failed:invalid_input_or_io');
    exitCode = 1;
  }
}

/// Offline only. Existing binary seed must be in a private directory, never in
/// the resource tree. No shell, HTTP client, upload, key generation or overwrite.
Future<void> buildDataUpdate({
  required String resources,
  required String metadata,
  required String seedFile,
  required String output,
}) async {
  Uint8List? seed;
  File? reservation;
  Directory? staging;
  final created = <File>[];
  try {
    final resourceRoot = await _canonical(
      resources,
      FileSystemEntityType.directory,
    );
    final metadataPath = await _canonical(metadata, FileSystemEntityType.file);
    if (!File(seedFile).isAbsolute) _reject('private_seed_required');
    final keyPath = await _canonical(seedFile, FileSystemEntityType.file);
    if (!File(keyPath).uri.pathSegments.contains('.private') ||
        _within(keyPath, resourceRoot) ||
        keyPath == metadataPath) {
      _reject('private_seed_required');
    }
    final requested = Directory(output).absolute;
    final parent = await _canonical(
      requested.parent.path,
      FileSystemEntityType.directory,
    );
    final name = requested.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$').hasMatch(name)) {
      _reject('invalid_output');
    }
    final destination = Directory('$parent/$name');
    if (_within(keyPath, destination.path) ||
        _within(destination.path, resourceRoot) ||
        await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      _reject('output_exists_or_overlaps');
    }
    final input = _metadata(utf8.decode(await _read(metadataPath, 4096)));
    final entries = await Directory(
      resourceRoot,
    ).list(followLinks: false).take(2).toList();
    if (entries.length != 1 ||
        entries.single.uri.pathSegments.where((v) => v.isNotEmpty).last !=
            'help') {
      _reject('unexpected_resource');
    }
    final helpRoot = await _canonical(
      '$resourceRoot/help',
      FileSystemEntityType.directory,
    );
    final helpEntries = await Directory(
      helpRoot,
    ).list(followLinks: false).take(2).toList();
    if (helpEntries.length != 1 ||
        helpEntries.single.uri.pathSegments.last != 'connection-ru.json') {
      _reject('unexpected_resource');
    }
    final resourcePath = await _canonical(
      '$helpRoot/connection-ru.json',
      FileSystemEntityType.file,
    );
    final bytes = await _read(resourcePath, 8192);
    try {
      parseConnectionHelp(bytes);
    } catch (_) {
      _reject('invalid_help');
    }
    seed = await _read(keyPath, 32);
    if (seed.length != 32) _reject('invalid_seed');
    final key = await Ed25519().newKeyPairFromSeed(seed);
    final public = await key.extractPublicKey();
    final keyId = input.remove('keyId');
    if (keyId is! String) _reject('invalid_metadata');
    final sha = hashes.sha256.convert(bytes).toString();
    final raw = utf8.encode(
      jsonEncode({
        'format': 1,
        ...input,
        'files': [
          {'path': connectionHelpPath, 'size': bytes.length, 'sha256': sha},
        ],
      }),
    );
    final signature = await Ed25519().sign(raw, keyPair: key);
    final envelope = utf8.encode(
      jsonEncode({
        'keyId': keyId,
        'manifest': base64.encode(raw),
        'signature': base64.encode(signature.bytes),
      }),
    );
    // Reserved .invalid URIs satisfy verifier policy only; no network is used.
    final policy = TrustedUpdatePolicy(
      manifestUri: Uri.parse('https://offline.invalid/manifest'),
      filesBaseUri: Uri.parse('https://offline.invalid/files/'),
      publicKeys: {keyId: public.bytes},
      resourceLimits: {connectionHelpPath: 8192},
      requiredPaths: {connectionHelpPath},
    );
    await ManifestVerifier(policy).verify(envelope);
    final publicInfo = utf8.encode(
      jsonEncode({'keyId': keyId, 'publicKey': base64.encode(public.bytes)}),
    );
    for (final outputBytes in [bytes, raw, envelope, publicInfo]) {
      if (_contains(outputBytes, seed) ||
          _contains(outputBytes, utf8.encode(base64.encode(seed))) ||
          _contains(
            outputBytes,
            utf8.encode(
              seed.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
            ),
          )) {
        _reject('private_material_in_output');
      }
    }
    final lock = File('$parent/.$name.authoring-lock');
    await lock.create(exclusive: true);
    reservation = lock;
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _reject('output_exists_or_overlaps');
    }
    staging = await Directory(parent).createTemp('.exvpn-author-');
    final payload = await Directory('${staging.path}/files').create();
    for (final entry in <String, List<int>>{
      '${staging.path}/manifest.json': envelope,
      '${payload.path}/$sha': bytes,
      '${staging.path}/public-key.json': publicInfo,
    }.entries) {
      final file = await File(entry.key).create(exclusive: true);
      created.add(file);
      await file.writeAsBytes(entry.value, flush: true);
    }
    // Other authoring invocations use the exclusive reservation. The parent
    // must be trusted; no guarantee against a same-user filesystem attacker.
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _reject('output_exists_or_overlaps');
    }
    await staging.rename(destination.path);
    staging = null;
  } on AuthoringFailure {
    rethrow;
  } on UpdateException {
    _reject('invalid_metadata');
  } catch (_) {
    _reject('invalid_input_or_io');
  } finally {
    seed?.fillRange(0, seed.length, 0);
    if (staging != null) {
      // Delete only exact files created by this invocation, no recursive delete.
      for (final file in created.reversed) {
        try {
          await file.delete();
        } catch (_) {}
      }
      try {
        await Directory('${staging.path}/files').delete();
      } catch (_) {}
      try {
        await staging.delete();
      } catch (_) {}
    }
    try {
      await reservation?.delete();
    } catch (_) {}
  }
}

bool _within(String path, String directory) {
  var candidate = File(path).absolute.uri.normalizePath().path;
  var parent = Directory(directory).absolute.uri.normalizePath().path;
  if (Platform.isWindows) {
    candidate = candidate.toLowerCase();
    parent = parent.toLowerCase();
  }
  return candidate.startsWith(parent);
}

Future<String> _canonical(String path, FileSystemEntityType type) async {
  final file = File(path).absolute;
  // Reject symbolic links in every component, not only the final entry.
  var current = file.path;
  while (true) {
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      _reject('link_denied');
    }
    final parent = Directory(current).parent.path;
    if (parent == current) break;
    current = parent;
  }
  if (await FileSystemEntity.type(file.path, followLinks: false) != type) {
    _reject('missing_input');
  }
  return file.resolveSymbolicLinks();
}

Future<Uint8List> _read(String path, int maximum) async {
  final handle = await File(path).open();
  try {
    if (await handle.length() > maximum) _reject('input_too_large');
    final bytes = await handle.read(maximum + 1);
    if (bytes.length > maximum) _reject('input_too_large');
    return bytes;
  } finally {
    await handle.close();
  }
}

Map<String, Object?> _metadata(String source) {
  // Flat JSON only. Tokenization preserves duplicate keys instead of silently
  // losing them through jsonDecode; each scalar is still parsed by Dart JSON.
  final token = RegExp(
    r'\s*("(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|-?(?:0|[1-9][0-9]*)|[{},:])',
  );
  final tokens = <String>[];
  var offset = 0;
  while (offset < source.length && source.substring(offset).trim().isNotEmpty) {
    final match = token.matchAsPrefix(source, offset);
    if (match == null) _reject('invalid_metadata');
    tokens.add(match.group(1)!);
    offset = match.end;
  }
  var at = 0;
  String next() {
    if (at >= tokens.length) _reject('invalid_metadata');
    return tokens[at++];
  }

  if (next() != '{') _reject('invalid_metadata');
  final values = <String, Object?>{};
  while (true) {
    final key = jsonDecode(next());
    if (key is! String || values.containsKey(key) || next() != ':') {
      _reject('invalid_metadata');
    }
    final value = jsonDecode(next());
    if (value is! String && value is! int) _reject('invalid_metadata');
    values[key] = value;
    final separator = next();
    if (separator == '}') break;
    if (separator != ',') _reject('invalid_metadata');
  }
  const required = {
    'keyId',
    'revision',
    'channel',
    'minVersion',
    'maxVersionExclusive',
    'minBuild',
    'maxBuild',
  };
  if (at != tokens.length ||
      !values.keys.toSet().containsAll(required) ||
      values.keys.any(
        (key) => !required.contains(key) && key != 'rollbackOf',
      )) {
    _reject('invalid_metadata');
  }
  return values;
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var at = 0; at <= haystack.length - needle.length; at++) {
    var equal = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[at + i] != needle[i]) {
        equal = false;
        break;
      }
    }
    if (equal) return true;
  }
  return false;
}
