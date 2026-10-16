import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum SubscriptionLoadErrorCode {
  invalidUrl,
  redirect,
  httpStatus,
  tooLarge,
  invalidEncoding,
  timeout,
  network,
  closed,
}

/// Contains no URL, response body, provider credentials, or underlying exception.
final class SubscriptionLoadException implements Exception {
  const SubscriptionLoadException(this.code);

  final SubscriptionLoadErrorCode code;

  @override
  String toString() => 'SubscriptionLoadException(${code.name})';
}

/// HTTPS-only text loading with one deadline for headers and the complete body.
///
/// Redirects are refused, including HTTPS redirects. Browser CORS failures and
/// browser-rejected redirects are reported as [SubscriptionLoadErrorCode.network]
/// because the browser intentionally hides their response details. A private
/// provider is permitted when its HTTPS certificate is trusted by the platform.
final class SubscriptionLoader {
  SubscriptionLoader({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.maxBytes = 2 * 1024 * 1024,
  }) : _client = client ?? http.Client() {
    if (timeout <= Duration.zero || maxBytes <= 0) {
      throw ArgumentError('Download limits must be positive.');
    }
  }

  final http.Client _client;
  final Duration timeout;
  final int maxBytes;
  final Set<_Download> _downloads = {};
  bool _closed = false;

  Future<String> load(String input) async {
    if (_closed) {
      throw const SubscriptionLoadException(SubscriptionLoadErrorCode.closed);
    }
    final uri = _parseUrl(input);
    final download = _Download();
    _downloads.add(download);
    download.deadline = Timer(timeout, () {
      download.fail(SubscriptionLoadErrorCode.timeout);
    });
    unawaited(_receive(uri, download));
    try {
      return await download.result.future;
    } finally {
      _downloads.remove(download);
    }
  }

  static Uri _parseUrl(String input) {
    final text = input.trim();
    Uri? uri;
    try {
      if (text.length <= 8192 &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(text) &&
          !RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(text)) {
        uri = Uri.tryParse(text);
      }
      if (uri == null ||
          uri.scheme != 'https' ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.authority.contains('@') ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw const FormatException();
      }
    } on FormatException {
      throw const SubscriptionLoadException(
        SubscriptionLoadErrorCode.invalidUrl,
      );
    }
    return uri;
  }

  Future<void> _receive(Uri uri, _Download download) async {
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: download.abort.future)
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['accept'] = 'text/plain, application/json, */*';
      final response = await _client.send(request);
      if (download.finished) {
        _cancel(response.stream.listen(null));
        return;
      }
      SubscriptionLoadErrorCode? rejection;
      if (response.statusCode >= 300 && response.statusCode < 400) {
        rejection = SubscriptionLoadErrorCode.redirect;
      } else if (response.statusCode != 200) {
        // A partial response (206) must never replace the complete subscription.
        rejection = SubscriptionLoadErrorCode.httpStatus;
      } else if ((response.contentLength ?? 0) > maxBytes) {
        rejection = SubscriptionLoadErrorCode.tooLarge;
      }
      if (rejection != null) {
        download.fail(rejection);
        _cancel(response.stream.listen(null));
        return;
      }
      final bytes = BytesBuilder(copy: false);
      download.body = response.stream.listen(
        (chunk) {
          if (download.finished) return;
          if (chunk.length > maxBytes - bytes.length) {
            download.fail(SubscriptionLoadErrorCode.tooLarge);
            return;
          }
          bytes.add(chunk);
        },
        onError: (Object error, StackTrace stack) {
          download.fail(SubscriptionLoadErrorCode.network);
        },
        onDone: () {
          if (download.finished) return;
          try {
            download.complete(utf8.decode(bytes.takeBytes()));
          } on FormatException {
            download.fail(SubscriptionLoadErrorCode.invalidEncoding);
          }
        },
        cancelOnError: true,
      );
    } catch (_) {
      download.fail(SubscriptionLoadErrorCode.network);
    }
  }

  /// Closes the owned/injected client and cancels outstanding subscriptions.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final download in _downloads) {
      download.fail(SubscriptionLoadErrorCode.closed);
    }
    _client.close();
  }
}

final class _Download {
  final result = Completer<String>();
  final abort = Completer<void>();
  StreamSubscription<List<int>>? body;
  Timer? deadline;

  bool get finished => result.isCompleted;

  void fail(SubscriptionLoadErrorCode code) {
    if (finished) return;
    _stop();
    result.completeError(SubscriptionLoadException(code));
  }

  void complete(String value) {
    if (finished) return;
    _stop();
    result.complete(value);
  }

  void _stop() {
    deadline?.cancel();
    if (!abort.isCompleted) abort.complete();
    if (body case final subscription?) _cancel(subscription);
  }
}

void _cancel(StreamSubscription<List<int>> subscription) {
  // Cancellation failures must not leak transport exceptions containing URLs.
  unawaited(subscription.cancel().catchError((Object _) {}));
}
