// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_updates_types.dart';

FullUpdatesBackend createFullUpdatesBackend() => Platform.isWindows
    ? WindowsFullUpdatesBackend()
    : const DisabledFullUpdatesBackend();

/// The installed helper owns its compiled feed, channel, trusted key and package
/// policy. A subscription or UI input cannot supply another executable or URL.
class WindowsFullUpdatesBackend implements FullUpdatesBackend {
  Process? _process;
  Future<void>? _stopped;
  bool _busy = false;
  bool _disposed = false;
  bool _cancelled = false;
  bool _cancellable = false;
  @override
  bool get supported => Platform.isWindows;

  @override
  Future<FullUpdateOffer?> check() async {
    final result = await _run('check');
    return result.status == 'upToDate' ? null : result.offer;
  }

  @override
  Future<FullUpdateOffer> download(
    FullUpdateOffer offer, {
    required FullUpdateProgressCallback onProgress,
  }) async => (await _run(
    'download',
    version: offer.version,
    onProgress: onProgress,
  )).offer!;

  @override
  Future<void> handoff(FullUpdateOffer offer) async {
    await _run('handoff', version: offer.version);
  }

  @override
  Future<void> restartUi() async {
    await _run('restart-ui');
  }

  Future<FullUpdateProtocolResult> _run(
    String command, {
    String? version,
    FullUpdateProgressCallback? onProgress,
  }) async {
    if (!supported) throw AppUpdatesFailure('unsupported_platform');
    if (_disposed) throw AppUpdatesFailure('cancelled');
    if (_busy) throw AppUpdatesFailure('operation_busy');
    if (version != null && !isFullUpdateIdentity(version)) {
      throw AppUpdatesFailure('invalid_request');
    }
    _busy = true;
    _cancelled = false;
    _cancellable = command == 'check' || command == 'download';
    final stopped = Completer<void>();
    _stopped = stopped.future;
    Process? process;
    try {
      final directory = File(Platform.resolvedExecutable).parent;
      final executable = directory.uri
          .resolve('exvpn-updater.exe')
          .toFilePath();
      if (!await File(executable).exists()) {
        throw AppUpdatesFailure('updater_unavailable');
      }
      if (_disposed || _cancelled) throw AppUpdatesFailure('cancelled');
      process = await Process.start(
        executable,
        [command, '--json'],
        workingDirectory: directory.path,
        runInShell: false,
      );
      _process = process;
      if (_disposed || _cancelled) throw AppUpdatesFailure('cancelled');
      final protocol = FullUpdateProtocol(
        command,
        expectedVersion: version,
        onProgress: onProgress,
      );
      final accepted = Completer<FullUpdateProtocolResult>();
      final output = _readOutput(
        process.stdout,
        protocol,
        onAccepted: () {
          if (!accepted.isCompleted) {
            accepted.complete(protocol.finish(exitCode: 0));
          }
        },
      );
      // Never retain diagnostics from a native process: even a malformed helper
      // cannot put a path, URL or exception into application state.
      final errors = _discardErrors(process.stderr);
      final input = () async {
        process!.stdin.writeln(
          jsonEncode({
            'protocol': 1,
            'version': ?version,
            if (command == 'handoff' || command == 'restart-ui')
              'parentPid': pid,
          }),
        );
        await process.stdin.close();
      }();
      final timeout = command == 'download'
          ? const Duration(minutes: 20)
          : command == 'check'
          ? const Duration(seconds: 20)
          : const Duration(seconds: 60);
      final completion = Future.wait<Object?>(
        [output, errors, input, process.exitCode],
        eagerError: true,
      ).then((values) => protocol.finish(exitCode: values.last! as int));
      final result = await Future.any([
        completion,
        if (command == 'handoff' || command == 'restart-ui') accepted.future,
      ]).timeout(timeout, onTimeout: () => throw AppUpdatesFailure('timeout'));
      if (protocol.handoffAccepted) return result;
      if (_cancelled || _disposed) throw AppUpdatesFailure('cancelled');
      return result;
    } catch (failure) {
      // Do not release the single-command gate until this exact child exits.
      // In particular, timeout is not permission to start a second download.
      process?.kill();
      if (process != null) await process.exitCode;
      if (_disposed || _cancelled) throw AppUpdatesFailure('cancelled');
      if (failure is AppUpdatesFailure) rethrow;
      throw AppUpdatesFailure('operation_failed');
    } finally {
      _process = null;
      _busy = false;
      _cancellable = false;
      stopped.complete();
    }
  }

  Future<void> _readOutput(
    Stream<List<int>> source,
    FullUpdateProtocol protocol, {
    required void Function() onAccepted,
  }) async {
    var bytes = 0;
    final bounded = source.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          bytes += chunk.length;
          if (bytes > 1024 * 1024) {
            sink.addError(AppUpdatesFailure('invalid_response'));
          } else {
            sink.add(chunk);
          }
        },
      ),
    );
    await for (final line
        in bounded.transform(utf8.decoder).transform(const LineSplitter())) {
      protocol.addLine(line);
      if (protocol.handoffAccepted) onAccepted();
    }
  }

  Future<void> _discardErrors(Stream<List<int>> source) async {
    var bytes = 0;
    await for (final chunk in source) {
      bytes += chunk.length;
      if (bytes > 16 * 1024) throw AppUpdatesFailure('invalid_response');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_busy || !_cancellable) return;
    _cancelled = true;
    _process?.kill();
    await _stopped;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_cancellable) {
      _cancelled = true;
      _process?.kill();
    }
  }
}

bool isFullUpdateIdentity(String value) {
  if (value.length > 48 || !_identity.hasMatch(value)) return false;
  final build = int.tryParse(value.split('+').last);
  return build != null && build > 0 && build <= 2147483647;
}

final _identity = RegExp(
  r'^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\+[1-9][0-9]{0,9}$',
);

class FullUpdateProtocolResult {
  const FullUpdateProtocolResult(this.status, this.offer);
  final String status;
  final FullUpdateOffer? offer;
}

/// Bounded NDJSON validation is separate from process execution so malformed
/// types, contradictory progress and unsolicited terminal replies are testable.
class FullUpdateProtocol {
  FullUpdateProtocol(this.command, {this.expectedVersion, this.onProgress});
  final String command;
  final String? expectedVersion;
  final FullUpdateProgressCallback? onProgress;
  Map<String, dynamic>? _terminal;
  int _received = 0;
  int? _total;
  bool get handoffAccepted =>
      (command == 'handoff' || command == 'restart-ui') &&
      _terminal?['status'] == 'accepted';

  void addLine(String line) {
    if (line.isEmpty || line.length > 16 * 1024 || _terminal != null) {
      throw AppUpdatesFailure('invalid_response');
    }
    Object? value;
    try {
      value = jsonDecode(line);
    } catch (_) {
      throw AppUpdatesFailure('invalid_response');
    }
    if (value is! Map<String, dynamic>) {
      throw AppUpdatesFailure('invalid_response');
    }
    if (value['type'] == 'progress' && command == 'download') {
      final received = value['received'];
      final total = value['total'];
      if (received is! int ||
          received < _received ||
          received < 0 ||
          (total != null && (total is! int || total < 1 || received > total)) ||
          (_total != null && total != _total)) {
        throw AppUpdatesFailure('invalid_response');
      }
      _received = received;
      _total = total as int?;
      onProgress?.call(FullUpdateProgress(received: received, total: _total));
      return;
    }
    if (value['type'] != 'result' || value['status'] is! String) {
      throw AppUpdatesFailure('invalid_response');
    }
    _terminal = value;
  }

  FullUpdateProtocolResult finish({required int exitCode}) {
    final value = _terminal;
    if (value == null) throw AppUpdatesFailure('invalid_response');
    if (value['status'] == 'error') {
      throw AppUpdatesFailure(safeAppUpdateCode(value['errorCode']));
    }
    final status = value['status'];
    final allowed = switch (command) {
      'check' => const {'upToDate', 'available', 'ready'},
      'download' => const {'ready'},
      'handoff' || 'restart-ui' => const {'accepted'},
      _ => const <String>{},
    };
    if (exitCode != 0 || !allowed.contains(status)) {
      throw AppUpdatesFailure('invalid_response');
    }
    final version = value['version'];
    final size = value['sizeBytes'];
    if (size != null &&
        (size is! int || size < 1 || size > 512 * 1024 * 1024)) {
      throw AppUpdatesFailure('invalid_response');
    }
    final needsVersion = status == 'available' || status == 'ready';
    if ((needsVersion && version == null) ||
        (version != null &&
            (version is! String || !isFullUpdateIdentity(version))) ||
        (expectedVersion != null && version != expectedVersion)) {
      throw AppUpdatesFailure('invalid_response');
    }
    return FullUpdateProtocolResult(
      status as String,
      version == null
          ? null
          : FullUpdateOffer(
              version: version as String,
              sizeBytes: size as int?,
            ),
    );
  }
}
