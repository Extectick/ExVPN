// SPDX-License-Identifier: Apache-2.0
part of '../exvpn_updates.dart';

typedef ResourceValidator =
    FutureOr<void> Function(String path, Uint8List bytes);

final class PreparedUpdate {
  PreparedUpdate._(
    this._owner,
    this._lease,
    this._directory,
    this.manifest,
    this.downloadedFiles,
    this.reusedFiles,
  );
  final DataUpdateClient _owner;
  final _StoreLease _lease;
  final Directory _directory;
  final VerifiedManifest manifest;
  final int downloadedFiles, reusedFiles;
  bool _consumed = false;
}

/// No timers, app restart, network policy or VPN commands. The host decides when
/// staged data may safely become active. Always activate or cancel a stage.
final class DataUpdateClient {
  DataUpdateClient({
    required this.policy,
    required this.context,
    required this.store,
    UpdateTransport? transport,
    this.validateResource,
  }) : _transport = transport ?? HttpsUpdateTransport(),
       _verifier = ManifestVerifier(policy);
  final TrustedUpdatePolicy policy;
  final UpdateContext context;
  final DirectoryUpdateStore store;
  final ResourceValidator? validateResource;
  final UpdateTransport _transport;
  final ManifestVerifier _verifier;
  bool _busy = false;
  PreparedUpdate? _prepared;

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_busy) _fail(UpdateError.busy);
    _busy = true;
    try {
      return await action();
    } on UpdateException {
      rethrow;
    } catch (_) {
      _fail(UpdateError.storageFailure);
    } finally {
      _busy = false;
    }
  }

  Future<RecoveryResult> recover() => _run(() async {
    if (_prepared != null) _fail(UpdateError.busy);
    final lease = await store._lock(context.channel);
    try {
      return (await store._recover(lease, _verifier, context)).result;
    } finally {
      await lease.close();
    }
  });

  Future<PreparedUpdate> stage() => _run(() async {
    if (_prepared != null) _fail(UpdateError.busy);
    final lease = await store._lock(context.channel);
    Directory? staging;
    try {
      final history = await store._recover(lease, _verifier, context);
      final timer = Stopwatch()..start();
      Duration remainingTimeout() {
        final left = policy.limits.downloadBudget - timer.elapsed;
        if (left <= Duration.zero) _fail(UpdateError.timeout);
        return left < policy.limits.requestTimeout
            ? left
            : policy.limits.requestTimeout;
      }

      final envelope = await _transport.get(
        policy.manifestUri,
        maxBytes: policy.limits.envelopeBytes,
        timeout: remainingTimeout(),
      );
      final manifest = await _verifier.verify(envelope);
      if (!manifest.supports(context)) _fail(UpdateError.incompatible);
      if (manifest.revision <= history.highestRevision) {
        _fail(UpdateError.staleRevision);
      }
      staging = await store._newStage(lease);
      var downloaded = 0, reused = 0;
      final current = history.result.active;
      for (final file in manifest.files) {
        Uint8List? bytes;
        final old = current?.manifest.files.where(
          (v) =>
              v.path == file.path &&
              v.sha256 == file.sha256 &&
              v.size == file.size,
        );
        if (old != null && old.isNotEmpty) {
          try {
            bytes = await current!.read(file.path);
            reused++;
          } catch (_) {
            /* Fetch and revalidate instead. */
          }
        }
        if (bytes == null) {
          bytes = await _transport.get(
            policy.filesBaseUri.resolve(file.sha256),
            maxBytes: file.size,
            timeout: remainingTimeout(),
          );
          downloaded++;
        }
        _verifyBytes(file, bytes);
        try {
          await validateResource?.call(file.path, bytes.asUnmodifiableView());
        } catch (_) {
          _fail(UpdateError.invalidManifest);
        }
        await store._writeResource(staging, file, bytes);
      }
      return _prepared = PreparedUpdate._(
        this,
        lease,
        staging,
        manifest,
        downloaded,
        reused,
      );
    } catch (_) {
      if (staging != null) {
        try {
          await store._remove(staging, lease.directory);
        } catch (_) {}
      }
      await lease.close();
      rethrow;
    }
  });

  Future<ActiveData> activate(
    PreparedUpdate prepared, {
    bool Function()? canActivate,
  }) => _run(() async {
    _checkPrepared(prepared);
    try {
      return await store._activate(
        prepared._lease,
        prepared._directory,
        prepared.manifest,
        _verifier,
        context,
        canActivate,
      );
    } finally {
      await _release(prepared);
    }
  });

  Future<void> cancel(PreparedUpdate prepared) => _run(() async {
    _checkPrepared(prepared);
    await _release(prepared);
  });

  void _checkPrepared(PreparedUpdate prepared) {
    if (!identical(prepared._owner, this) ||
        !identical(_prepared, prepared) ||
        prepared._consumed) {
      _fail(UpdateError.stageUnavailable);
    }
  }

  Future<void> _release(PreparedUpdate prepared) async {
    prepared._consumed = true;
    _prepared = null;
    try {
      await store._remove(prepared._directory, prepared._lease.directory);
    } catch (_) {
      /* Orphan staging is cleaned under the next process lease. */
    }
    await prepared._lease.close();
  }
}
