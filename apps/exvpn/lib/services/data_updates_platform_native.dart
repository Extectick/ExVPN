// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:path_provider/path_provider.dart';

import '../build_identity.dart';
import 'data_updates_types.dart';

DataUpdatesBackend createDataUpdatesBackend() {
  if (!Platform.isAndroid && !Platform.isWindows) {
    return DisabledDataUpdatesBackend('unsupported_platform');
  }
  return configuredDataUpdatesBackend(
    manifest: const String.fromEnvironment('EXVPN_DATA_MANIFEST'),
    files: const String.fromEnvironment('EXVPN_DATA_FILES'),
    keyId: const String.fromEnvironment('EXVPN_DATA_KEY_ID'),
    publicKey: const String.fromEnvironment('EXVPN_DATA_PUBLIC_KEY'),
    channel: const String.fromEnvironment(
      'EXVPN_DATA_CHANNEL',
      defaultValue: 'stable',
    ),
  );
}

// Parameters are supplied only by the compile-time factory above. This function
// is exposed for tests, never wired to subscriptions, preferences or import UI.
DataUpdatesBackend configuredDataUpdatesBackend({
  required String manifest,
  required String files,
  required String keyId,
  required String publicKey,
  required String channel,
}) {
  if ([manifest, files, keyId, publicKey].every((value) => value.isEmpty)) {
    return DisabledDataUpdatesBackend();
  }
  try {
    final selectedChannel = UpdateChannel.values.byName(channel);
    final policy = TrustedUpdatePolicy(
      manifestUri: Uri.parse(manifest),
      filesBaseUri: Uri.parse(files),
      publicKeys: {keyId: base64.decode(publicKey)},
      resourceLimits: {connectionHelpPath: 8192},
      requiredPaths: {connectionHelpPath},
      limits: const UpdateLimits(
        fileBytes: 8192,
        bundleBytes: 8192,
        maxFiles: 1,
      ),
    );
    return NativeDataUpdatesBackend(selectedChannel.name, () async {
      final root = await getApplicationSupportDirectory();
      return DataUpdateClient(
        policy: policy,
        context: UpdateContext(
          appVersion: appVersion,
          build: appBuild,
          channel: selectedChannel,
        ),
        store: DirectoryUpdateStore(Directory('${root.path}/signed-data-v1')),
        validateResource: (path, bytes) {
          if (path != connectionHelpPath) {
            throw const DataUpdatesFailure('invalid_resource');
          }
          parseConnectionHelp(bytes);
        },
      );
    });
  } catch (_) {
    return DisabledDataUpdatesBackend('invalid_configuration');
  }
}

/// One instance for the app lifetime; the client and its writer lease remain in
/// the UI isolate. Factory injection permits disk/TLS fixtures without OS paths.
final class NativeDataUpdatesBackend implements DataUpdatesBackend {
  NativeDataUpdatesBackend(this.channel, this._factory);
  final Future<DataUpdateClient> Function() _factory;
  Future<DataUpdateClient>? _clientFuture;
  PreparedUpdate? _prepared;
  @override
  final String channel;
  @override
  bool get enabled => true;
  @override
  String? get disabledReason => null;
  Future<DataUpdateClient> get _client async {
    final pending = _clientFuture ??= _factory();
    try {
      return await pending;
    } catch (_) {
      if (identical(pending, _clientFuture)) _clientFuture = null;
      rethrow;
    }
  }

  Future<T> _safe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DataUpdatesFailure {
      rethrow;
    } on UpdateException catch (error) {
      throw DataUpdatesFailure(error.code.name);
    } catch (_) {
      throw const DataUpdatesFailure('storageFailure');
    }
  }

  Future<DataUpdateSnapshot> _snapshot(
    ActiveData? active, {
    bool recovered = false,
  }) async {
    if (active == null) return const DataUpdateSnapshot();
    return DataUpdateSnapshot(
      revision: active.manifest.revision,
      help: parseConnectionHelp(await active.read(connectionHelpPath)),
      recoveredPrevious: recovered,
    );
  }

  @override
  Future<DataUpdateSnapshot> recover() => _safe(() async {
    final result = await (await _client).recover();
    if (result.highestRevision > 0 && result.active == null) {
      throw const DataUpdatesFailure('corruptState');
    }
    return _snapshot(result.active, recovered: result.recoveredPrevious);
  });

  @override
  Future<DataUpdateProposal> stage() => _safe(() async {
    final prepared = await (await _client).stage();
    _prepared = prepared;
    return DataUpdateProposal(
      prepared.manifest.revision,
      prepared.downloadedFiles,
      prepared.reusedFiles,
    );
  });

  @override
  Future<DataUpdateSnapshot> apply(bool Function() canActivate) => _safe(
    () async {
      final prepared = _prepared;
      if (prepared == null) throw const DataUpdatesFailure('stageUnavailable');
      _prepared =
          null; // activate consumes the stage on both success and failure.
      final active = await (await _client).activate(
        prepared,
        canActivate: canActivate,
      );
      return _snapshot(active);
    },
  );

  @override
  Future<void> cancel() => _safe(() async {
    final prepared = _prepared;
    if (prepared != null) {
      _prepared = null;
      await (await _client).cancel(prepared);
    }
  });
}
