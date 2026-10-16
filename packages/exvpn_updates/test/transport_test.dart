// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:exvpn_updates/exvpn_updates.dart';
import 'package:test/test.dart';
import 'support.dart';
import 'tls_fixture.dart';

void main() {
  late HttpServer server;
  late HttpsUpdateTransport transport;
  late Uri base;
  late StreamSubscription<HttpRequest> subscription;
  final requested = <String>[];
  setUp(() async {
    requested.clear();
    final contexts = await localTLSContexts();
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      contexts.$1,
    );
    base = Uri.parse('https://127.0.0.1:${server.port}/');
    transport = HttpsUpdateTransport.forTesting(
      () => HttpClient(context: contexts.$2),
    );
    subscription = server.listen(
      (request) async {
        requested.add(request.uri.path);
        final response = request.response;
        try {
          switch (request.uri.path) {
            case '/redirect':
              response.statusCode = 302;
              response.headers.set('location', base.resolve('ok').toString());
            case '/partial':
              response.statusCode = 206;
              response.add([1, 2]);
            case '/too-long':
              response.contentLength = 4;
              response.add([1, 2, 3, 4]);
            case '/chunked':
              response.add([1, 2]);
              await response.flush();
              response.add([3, 4]);
            case '/encoded':
              response.headers.set('content-encoding', 'gzip');
              response.add([1]);
            case '/slow':
              await Future<void>.delayed(const Duration(milliseconds: 300));
              response.add([1]);
            default:
              response.contentLength = 3;
              response.add([1, 2, 3]);
          }
          await response.close();
        } catch (_) {
          /* Timeout intentionally closes the peer socket. */
        }
      },
      onError: (Object _) {
        /* The untrusted-certificate test aborts TLS. */
      },
    );
  });
  tearDown(() async {
    await server.close(force: true);
    await subscription.cancel();
  });

  test(
    'HTTPS validates fixture certificate without changing system trust',
    () async {
      expect(
        await transport.get(
          base.resolve('ok'),
          maxBytes: 3,
          timeout: const Duration(seconds: 2),
        ),
        [1, 2, 3],
      );
      await expectLater(
        HttpsUpdateTransport().get(
          base.resolve('ok'),
          maxBytes: 3,
          timeout: const Duration(seconds: 2),
        ),
        fails(UpdateError.downloadFailed),
      );
    },
  );
  test(
    'redirects and partial responses never fetch another location',
    () async {
      await expectLater(
        transport.get(
          base.resolve('redirect'),
          maxBytes: 8,
          timeout: const Duration(seconds: 2),
        ),
        fails(UpdateError.downloadFailed),
      );
      expect(requested, ['/redirect']);
      await expectLater(
        transport.get(
          base.resolve('partial'),
          maxBytes: 8,
          timeout: const Duration(seconds: 2),
        ),
        fails(UpdateError.downloadFailed),
      );
    },
  );
  test(
    'declared and actual streamed size are both bounded; compression is refused',
    () async {
      for (final path in ['too-long', 'chunked']) {
        await expectLater(
          transport.get(
            base.resolve(path),
            maxBytes: 3,
            timeout: const Duration(seconds: 2),
          ),
          fails(UpdateError.tooLarge),
        );
      }
      await expectLater(
        transport.get(
          base.resolve('encoded'),
          maxBytes: 8,
          timeout: const Duration(seconds: 2),
        ),
        fails(UpdateError.downloadFailed),
      );
    },
  );
  test('whole-response timeout aborts stalled download', () async {
    final timer = Stopwatch()..start();
    await expectLater(
      transport.get(
        base.resolve('slow'),
        maxBytes: 3,
        timeout: const Duration(milliseconds: 80),
      ),
      fails(UpdateError.timeout),
    );
    expect(timer.elapsed, lessThan(const Duration(seconds: 1)));
  });
  test('unsafe URLs fail before a socket is created', () async {
    for (final uri in [
      Uri.parse('http://127.0.0.1/'),
      Uri.parse('https://user:pass@127.0.0.1/'),
      base.replace(fragment: 'secret'),
    ]) {
      await expectLater(
        transport.get(uri, maxBytes: 1, timeout: const Duration(seconds: 1)),
        fails(UpdateError.invalidPolicy),
      );
    }
    expect(requested, isEmpty);
  });
}
