// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

const connectionHelpPath = 'help/connection-ru.json';
const bundledConnectionHelp =
    'Выберите сервер и нажмите кнопку подключения. Если сервер не отвечает, '
    'проверьте сеть и попробуйте другое подключение из подписки. '
    'Обновление подписки доступно по значку рядом с плюсом.';

/// Plain display text only; never a URL action, core setting or executable.
String parseConnectionHelp(Uint8List bytes) {
  try {
    if (bytes.length > 8192) throw const FormatException();
    final raw = utf8.decode(bytes);
    const text = r'"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"';
    // This flat schema admits either field order, but no duplicate, unknown or
    // escaped field name. jsonDecode additionally validates JSON string escapes.
    final shape = RegExp(
      '^\\s*\\{\\s*(?:'
      '"format"\\s*:\\s*1\\s*,\\s*"body"\\s*:\\s*$text|'
      '"body"\\s*:\\s*$text\\s*,\\s*"format"\\s*:\\s*1'
      ')\\s*\\}\\s*\$',
    );
    if (!shape.hasMatch(raw)) throw const FormatException();
    final value = jsonDecode(raw) as Map<String, dynamic>;
    final body = value['body'] as String;
    if (body.trim().isEmpty ||
        body.length > 1500 ||
        RegExp(
          r'[\x00-\x09\x0b-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
        ).hasMatch(body)) {
      throw const FormatException();
    }
    return body.trim();
  } catch (_) {
    throw const DataUpdatesFailure('invalid_resource');
  }
}

final class DataUpdatesFailure implements Exception {
  const DataUpdatesFailure(this.code);
  final String code;
  @override
  String toString() => 'DataUpdatesFailure';
}

final class DataUpdateSnapshot {
  const DataUpdateSnapshot({
    this.revision,
    this.help = bundledConnectionHelp,
    this.recoveredPrevious = false,
  });
  final int? revision;
  final String help;
  final bool recoveredPrevious;
}

final class DataUpdateProposal {
  const DataUpdateProposal(
    this.revision,
    this.downloadedFiles,
    this.reusedFiles,
  );
  final int revision, downloadedFiles, reusedFiles;
}

abstract interface class DataUpdatesBackend {
  bool get enabled;
  String? get disabledReason;
  String get channel;
  Future<DataUpdateSnapshot> recover();
  Future<DataUpdateProposal> stage();
  Future<DataUpdateSnapshot> apply(bool Function() canActivate);
  Future<void> cancel();
}

final class DisabledDataUpdatesBackend implements DataUpdatesBackend {
  DisabledDataUpdatesBackend([this.disabledReason = 'not_configured']);
  @override
  final String disabledReason;
  @override
  bool get enabled => false;
  @override
  String get channel => 'stable';
  @override
  Future<DataUpdateSnapshot> recover() async => const DataUpdateSnapshot();
  @override
  Future<DataUpdateProposal> stage() async =>
      throw const DataUpdatesFailure('disabled');
  @override
  Future<DataUpdateSnapshot> apply(bool Function() canActivate) async =>
      throw const DataUpdatesFailure('disabled');
  @override
  Future<void> cancel() async {}
}
