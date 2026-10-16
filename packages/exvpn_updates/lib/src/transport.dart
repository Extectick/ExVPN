// SPDX-License-Identifier: Apache-2.0
part of '../exvpn_updates.dart';

abstract interface class UpdateTransport {
  Future<Uint8List> get(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  });
}

final class HttpsUpdateTransport implements UpdateTransport {
  HttpsUpdateTransport() : _clientFactory = HttpClient.new;

  /// Test-only TLS fixture trust can be supplied without altering OS roots.
  HttpsUpdateTransport.forTesting(HttpClient Function() clientFactory)
    : _clientFactory = clientFactory;
  final HttpClient Function() _clientFactory;

  @override
  Future<Uint8List> get(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
  }) async {
    if (!_secureUri(uri) || maxBytes < 0 || timeout <= Duration.zero) {
      _fail(UpdateError.invalidPolicy);
    }
    final client = _clientFactory()
      ..autoUncompress = false
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.maxRedirects = 0;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          _fail(UpdateError.downloadFailed);
        }
        final encoding = response.headers.value(
          HttpHeaders.contentEncodingHeader,
        );
        if (encoding != null && encoding != 'identity') {
          _fail(UpdateError.downloadFailed);
        }
        if (response.contentLength > maxBytes) _fail(UpdateError.tooLarge);
        final output = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (output.length + chunk.length > maxBytes) {
            _fail(UpdateError.tooLarge);
          }
          output.add(chunk);
        }
        if (response.contentLength >= 0 &&
            output.length != response.contentLength) {
          _fail(UpdateError.downloadFailed);
        }
        return output.takeBytes();
      })().timeout(timeout);
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      _fail(UpdateError.timeout);
    } catch (_) {
      _fail(UpdateError.downloadFailed);
    } finally {
      client.close(force: true);
    }
  }
}
