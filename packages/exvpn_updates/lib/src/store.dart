// SPDX-License-Identifier: Apache-2.0
part of '../exvpn_updates.dart';

enum StorageOperation {
  createStage,
  writeResource,
  sealBundle,
  writeCommit,
  publishCommit,
}

typedef StorageFaultHook = FutureOr<void> Function(StorageOperation operation);

/// App-private directory only. One lease spans staging through activation or
/// cancellation; the OS releases the lease if the process dies. All clients for
/// one root must run in one writer isolate (POSIX file locks are process-level).
final class DirectoryUpdateStore {
  DirectoryUpdateStore(this.root) : _fault = null;
  DirectoryUpdateStore.forTesting(
    this.root, {
    StorageFaultHook? beforeOperation,
  }) : _fault = beforeOperation;
  final Directory root;
  final StorageFaultHook? _fault;
  static final _leases = <String>{};

  Future<void> _checkpoint(StorageOperation operation) async {
    await _fault?.call(operation);
  }

  Future<_StoreLease> _lock(UpdateChannel channel) async {
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      _fail(UpdateError.storageFailure);
    }
    final canonical = Directory(await root.resolveSymbolicLinks());
    final directory = Directory('${canonical.path}/${channel.name}');
    await _directory(directory);
    final identity = Platform.isWindows
        ? directory.path.toLowerCase()
        : directory.path;
    // Reserve before opening the file: on POSIX closing another handle for the
    // same file may release the process's existing advisory lock.
    if (!_leases.add(identity)) _fail(UpdateError.busy);
    final lock = File('${directory.path}/writer.lock');
    RandomAccessFile? handle;
    try {
      final kind = await FileSystemEntity.type(lock.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.file) {
        _fail(UpdateError.storageFailure);
      }
      handle = await lock.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        _fail(UpdateError.busy);
      }
      return _StoreLease(directory, handle, identity);
    } catch (_) {
      try {
        await handle?.close();
      } finally {
        _leases.remove(identity);
      }
      rethrow;
    }
  }

  Future<void> _directory(Directory value) async {
    final kind = await FileSystemEntity.type(value.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      await value.create();
      return;
    }
    if (kind != FileSystemEntityType.directory) {
      _fail(UpdateError.storageFailure);
    }
  }

  Future<List<FileSystemEntity>> _entries(Directory directory) async {
    final entries = <FileSystemEntity>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entries.length >= 256) _fail(UpdateError.corruptState);
      entries.add(entry);
    }
    return entries;
  }

  Future<Uint8List> _read(File file, int maximum) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      _fail(UpdateError.corruptState);
    }
    final handle = await file.open();
    try {
      if (await handle.length() > maximum) _fail(UpdateError.tooLarge);
      final bytes = await handle.read(maximum + 1);
      if (bytes.length > maximum) _fail(UpdateError.tooLarge);
      return bytes;
    } finally {
      await handle.close();
    }
  }

  Future<File> _resource(
    Directory bundle,
    String path, {
    bool create = false,
  }) async {
    if (!_safeResourcePath(path)) _fail(UpdateError.pathDenied);
    if (await FileSystemEntity.type(bundle.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      _fail(UpdateError.corruptState);
    }
    var directory = bundle;
    final parts = path.split('/');
    for (final part in parts.take(parts.length - 1)) {
      directory = Directory('${directory.path}/$part');
      if (create) {
        await _directory(directory);
      } else if (await FileSystemEntity.type(
            directory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        _fail(UpdateError.corruptState);
      }
    }
    final file = File('${directory.path}/${parts.last}');
    final kind = await FileSystemEntity.type(file.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.file) {
      _fail(UpdateError.pathDenied);
    }
    return file;
  }

  Future<Uint8List> _readResource(Directory bundle, ResourceFile spec) async {
    final bytes = await _read(await _resource(bundle, spec.path), spec.size);
    _verifyBytes(spec, bytes);
    return bytes;
  }

  Future<bool> _validBundle(Directory bundle, VerifiedManifest manifest) async {
    try {
      for (final file in manifest.files) {
        await _readResource(bundle, file);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<_History> _recover(
    _StoreLease lease,
    ManifestVerifier verifier,
    UpdateContext context,
  ) async {
    final commits = Directory('${lease.directory.path}/commits');
    final bundles = Directory('${lease.directory.path}/bundles');
    await _directory(commits);
    await _directory(bundles);
    final candidates = <(int, File, String)>[];
    for (final entity in await _entries(commits)) {
      final name = entity.uri.pathSegments.where((v) => v.isNotEmpty).last;
      final match = RegExp(
        r'^r([1-9][0-9]{0,15})-([0-9a-f]{64})\.json$',
      ).firstMatch(name);
      if (match == null) {
        continue; // Incomplete .pending files are never activated.
      }
      final revision = int.tryParse(match.group(1)!);
      if (revision == null || revision > _maxInteger) {
        _fail(UpdateError.corruptState);
      }
      // Normally only current + previous remain. Bound repeated hashing after
      // damaged storage or repeated cleanup failures rather than scanning GBs.
      if (candidates.length >= 8) _fail(UpdateError.corruptState);
      candidates.add((revision, File(entity.path), match.group(2)!));
    }
    candidates.sort((a, b) => b.$1.compareTo(a.$1));
    final valid = <_Commit>[];
    final seen = <int>{};
    for (final item in candidates) {
      // Two distinct activated manifests for one revision are ambiguous: never
      // select one according to filesystem enumeration order.
      if (!seen.add(item.$1)) _fail(UpdateError.corruptState);
      try {
        final manifest = await verifier.verify(
          await _read(item.$2, verifier.policy.limits.envelopeBytes),
        );
        if (manifest.revision != item.$1 ||
            manifest.sha256 != item.$3 ||
            !manifest.supports(context)) {
          continue;
        }
        final bundle = Directory('${bundles.path}/${manifest.sha256}');
        if (await _validBundle(bundle, manifest)) {
          valid.add(_Commit(item.$2, ActiveData._(this, bundle, manifest)));
        }
      } catch (_) {
        /* A previous independently verified snapshot may recover. */
      }
    }
    // Keep the highest committed revision even when its payload is damaged.
    // Local deletion/tampering of the whole app store is outside this counter's
    // guarantee; no OS-backed monotonic hardware counter is claimed.
    return _History(candidates.isEmpty ? 0 : candidates.first.$1, valid);
  }

  Future<Directory> _newStage(_StoreLease lease) async {
    // No other live writer owns a stage while this OS lease is held. Remove only
    // our known abandoned names; commit/bundle data is never removed here.
    for (final entry in await _entries(lease.directory)) {
      final name = entry.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (RegExp(r'^stage-[0-9a-f]{32}$').hasMatch(name)) {
        await _remove(entry, lease.directory);
      }
    }
    await _checkpoint(StorageOperation.createStage);
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return Directory('${lease.directory.path}/stage-$nonce').create();
  }

  Future<void> _writeResource(
    Directory stage,
    ResourceFile file,
    List<int> bytes,
  ) async {
    _verifyBytes(file, bytes);
    await _checkpoint(StorageOperation.writeResource);
    await (await _resource(
      stage,
      file.path,
      create: true,
    )).writeAsBytes(bytes, flush: true);
  }

  Future<ActiveData> _activate(
    _StoreLease lease,
    Directory stage,
    VerifiedManifest manifest,
    ManifestVerifier verifier,
    UpdateContext context,
    bool Function()? canActivate,
  ) async {
    final before = await _recover(lease, verifier, context);
    if (manifest.revision <= before.highestRevision) {
      _fail(UpdateError.staleRevision);
    }
    if (!await _validBundle(stage, manifest)) _fail(UpdateError.hashMismatch);
    final bundle = Directory(
      '${lease.directory.path}/bundles/${manifest.sha256}',
    );
    await _checkpoint(StorageOperation.sealBundle);
    final existing = await FileSystemEntity.type(
      bundle.path,
      followLinks: false,
    );
    if (existing != FileSystemEntityType.notFound) {
      // Only an uncommitted identical revision can be here, because the floor
      // was checked above. Reuse it only after complete validation.
      if (!await _validBundle(bundle, manifest)) {
        _fail(UpdateError.corruptState);
      }
      await _remove(stage, lease.directory);
    } else {
      await stage.rename(bundle.path);
    }
    final commits = Directory('${lease.directory.path}/commits');
    final marker = File(
      '${commits.path}/r${manifest.revision}-${manifest.sha256}.json',
    );
    final pending = File('${commits.path}/.pending-${manifest.sha256}');
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(pending.path, followLinks: false) ==
            FileSystemEntityType.link) {
      _fail(UpdateError.corruptState);
    }
    await _checkpoint(StorageOperation.writeCommit);
    await pending.writeAsBytes(manifest.envelope, flush: true);
    await _checkpoint(StorageOperation.publishCommit);
    if (canActivate != null && !canActivate()) {
      _fail(UpdateError.activationDeferred);
    }
    // Single atomic visibility point: rename a flushed marker to a NEW name on
    // the same filesystem. No replace/delete gap for a current pointer on Windows.
    await pending.rename(marker.path);
    final active = ActiveData._(this, bundle, manifest);
    // Post-commit cleanup is best-effort. Failure cannot turn an already visible
    // successful activation into an apparent failed transaction.
    try {
      await _prune(
        lease,
        active,
        before.valid.isEmpty ? null : before.valid.first.active,
      );
    } catch (_) {}
    return active;
  }

  Future<void> _prune(
    _StoreLease lease,
    ActiveData current,
    ActiveData? previous,
  ) async {
    final keep = {
      current.manifest.sha256,
      if (previous != null) previous.manifest.sha256,
    };
    final commits = Directory('${lease.directory.path}/commits');
    for (final entry in await _entries(commits)) {
      final name = entry.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (!keep.any((hash) => name.endsWith('-$hash.json'))) {
        await _remove(entry, lease.directory);
      }
    }
    final bundles = Directory('${lease.directory.path}/bundles');
    for (final entry in await _entries(bundles)) {
      final name = entry.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(name) && !keep.contains(name)) {
        await _remove(entry, lease.directory);
      }
    }
  }

  Future<void> _remove(FileSystemEntity entity, Directory boundary) async {
    // URI normalization handles mixed slash/backslash paths on Windows while
    // still requiring a strict descendant of the explicit store boundary.
    final prefix = boundary.absolute.uri.normalizePath().path;
    final absolute = entity.absolute.uri.normalizePath().path;
    if (absolute.length <= prefix.length ||
        !(Platform.isWindows
            ? absolute.toLowerCase().startsWith(prefix.toLowerCase())
            : absolute.startsWith(prefix))) {
      _fail(UpdateError.storageFailure);
    }
    final kind = await FileSystemEntity.type(entity.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return;
    if (kind == FileSystemEntityType.directory) {
      final directory = Directory(entity.path);
      for (final child in await _entries(directory)) {
        await _remove(child, boundary);
      }
      await directory.delete();
    } else if (kind == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    } else {
      await File(entity.path).delete();
    }
  }
}

void _verifyBytes(ResourceFile file, List<int> bytes) {
  if (bytes.length != file.size ||
      digest.sha256.convert(bytes).toString() != file.sha256) {
    _fail(UpdateError.hashMismatch);
  }
}

final class _StoreLease {
  _StoreLease(this.directory, this.handle, this.identity);
  final Directory directory;
  final RandomAccessFile handle;
  final String identity;
  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await handle.unlock();
    } catch (_) {
      // Closing still releases an OS lock. Cleanup cannot reverse a commit.
    }
    try {
      await handle.close();
      DirectoryUpdateStore._leases.remove(identity);
    } catch (_) {
      // An unclosed handle retains its isolate reservation: a future operation
      // fails busy rather than racing a possibly retained OS lease.
    }
  }
}

final class _Commit {
  _Commit(this.marker, this.active);
  final File marker;
  final ActiveData active;
}

final class _History {
  _History(this.highestRevision, this.valid);
  final int highestRevision;
  final List<_Commit> valid;
  RecoveryResult get result => RecoveryResult._(
    valid.isEmpty ? null : valid.first.active,
    highestRevision,
  );
}

final class RecoveryResult {
  RecoveryResult._(this.active, this.highestRevision);
  final ActiveData? active;
  final int highestRevision;
  bool get recoveredPrevious =>
      highestRevision > 0 && active?.manifest.revision != highestRevision;
}

/// Accessors re-check each resource; the updater never executes resource bytes.
final class ActiveData {
  ActiveData._(this._store, this._bundle, this.manifest);
  final DirectoryUpdateStore _store;
  final Directory _bundle;
  final VerifiedManifest manifest;
  Future<Uint8List> read(String path) async {
    final entries = manifest.files.where((f) => f.path == path);
    if (entries.isEmpty) _fail(UpdateError.pathDenied);
    try {
      return await _store._readResource(_bundle, entries.single);
    } on UpdateException {
      rethrow;
    } catch (_) {
      _fail(UpdateError.storageFailure);
    }
  }
}
