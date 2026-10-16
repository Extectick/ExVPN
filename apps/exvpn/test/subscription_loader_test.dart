import 'dart:async';
import 'dart:convert';

import 'package:exvpn/services/subscription_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _url = 'https://provider.example/sub/synthetic-token';

Matcher failsWith(SubscriptionLoadErrorCode code) => throwsA(
  isA<SubscriptionLoadException>().having((error) => error.code, 'code', code),
);

void main() {
  test('loads UTF-8 text and explicitly disables redirects', () async {
    final loader = SubscriptionLoader(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response.bytes(utf8.encode('тест подписки'), 200);
      }),
    );
    addTearDown(loader.close);
    expect(await loader.load('  $_url  '), 'тест подписки');
  });

  for (final invalid in [
    'http://provider.example/sub',
    'file:///secret',
    'provider.example/sub',
    'https:///sub',
    'https://user:password@provider.example/sub',
    'https://@provider.example/sub',
    'https://provider.example/sub#fragment',
    'https://provider.example/sub#',
    'https://provider.example:0/sub',
    'https://provider.example:65536/sub',
    'https://provider.example/sub\nother',
    'https://provider.example/sub with spaces',
    'https://[bad]/sub',
    '',
  ]) {
    test(
      'refuses unsafe/malformed URL ${invalid.length}:${invalid.hashCode}',
      () async {
        var called = false;
        final loader = SubscriptionLoader(
          client: MockClient((_) async {
            called = true;
            return http.Response('unexpected', 200);
          }),
        );
        addTearDown(loader.close);
        await expectLater(
          loader.load(invalid),
          failsWith(SubscriptionLoadErrorCode.invalidUrl),
        );
        expect(called, isFalse);
      },
    );
  }

  test(
    'allows HTTPS private providers without changing certificate checks',
    () async {
      final loader = SubscriptionLoader(
        client: MockClient((request) async {
          expect(request.url.host, '192.0.2.1');
          return http.Response('synthetic', 200);
        }),
      );
      addTearDown(loader.close);
      expect(await loader.load('https://192.0.2.1:8443/sub'), 'synthetic');
    },
  );

  for (final status in [301, 302, 303, 307, 308]) {
    test('refuses redirect $status without a follow-up request', () async {
      var requests = 0;
      final loader = SubscriptionLoader(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '',
            status,
            headers: {'location': 'http://other.example/secret'},
          );
        }),
      );
      addTearDown(loader.close);
      await expectLater(
        loader.load(_url),
        failsWith(SubscriptionLoadErrorCode.redirect),
      );
      expect(requests, 1);
    });
  }

  for (final status in [204, 206, 401, 404, 500]) {
    test('refuses incomplete or failed HTTP response $status', () async {
      final loader = SubscriptionLoader(
        client: MockClient((_) async => http.Response('private body', status)),
      );
      addTearDown(loader.close);
      await expectLater(
        loader.load(_url),
        failsWith(SubscriptionLoadErrorCode.httpStatus),
      );
    });
  }

  test('rejects an oversized declared length before reading', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final loader = SubscriptionLoader(
      maxBytes: 4,
      client: MockClient.streaming(
        (_, _) async =>
            http.StreamedResponse(stream.stream, 200, contentLength: 5),
      ),
    );
    addTearDown(loader.close);
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.tooLarge),
    );
    expect(cancelled, isTrue);
    await stream.close();
  });

  test(
    'counts actual streamed bytes despite misleading Content-Length',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final loader = SubscriptionLoader(
        maxBytes: 4,
        client: MockClient.streaming(
          (_, _) async =>
              http.StreamedResponse(stream.stream, 200, contentLength: 1),
        ),
      );
      addTearDown(loader.close);
      final result = expectLater(
        loader.load(_url),
        failsWith(SubscriptionLoadErrorCode.tooLarge),
      );
      stream.add([65, 66, 67]);
      stream.add([68, 69]);
      await result;
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test('accepts exactly the byte limit including multibyte text', () async {
    final loader = SubscriptionLoader(
      maxBytes: 4,
      client: MockClient(
        (_) async => http.Response.bytes(utf8.encode('ёж'), 200),
      ),
    );
    addTearDown(loader.close);
    expect(await loader.load(_url), 'ёж');
  });

  test('rejects malformed UTF-8 without replacement characters', () async {
    final loader = SubscriptionLoader(
      client: MockClient((_) async => http.Response.bytes([0xc3, 0x28], 200)),
    );
    addTearDown(loader.close);
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.invalidEncoding),
    );
  });

  test('header timeout aborts request and reports only a safe code', () async {
    var aborted = false;
    final loader = SubscriptionLoader(
      timeout: const Duration(milliseconds: 10),
      client: MockClient.streaming((request, _) async {
        final abort = (request as http.Abortable).abortTrigger!;
        await abort;
        aborted = true;
        throw http.RequestAbortedException(request.url);
      }),
    );
    addTearDown(loader.close);
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.timeout),
    );
    expect(aborted, isTrue);
  });

  test('total deadline cancels a stalled body stream', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final loader = SubscriptionLoader(
      timeout: const Duration(milliseconds: 10),
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(stream.stream, 200),
      ),
    );
    addTearDown(loader.close);
    stream.add([65]);
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.timeout),
    );
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('network and browser CORS failures never expose credentials', () async {
    final loader = SubscriptionLoader(
      client: MockClient((request) async {
        throw http.ClientException(
          'private diagnostic synthetic-token',
          request.url,
        );
      }),
    );
    addTearDown(loader.close);
    try {
      await loader.load(_url);
      fail('Expected a safe failure');
    } on SubscriptionLoadException catch (error) {
      expect(error.code, SubscriptionLoadErrorCode.network);
      expect(error.toString(), 'SubscriptionLoadException(network)');
      expect(error.toString(), isNot(contains('synthetic-token')));
      expect(error.toString(), isNot(contains('provider.example')));
    }
  });

  test('stream transport error is sanitized', () async {
    final loader = SubscriptionLoader(
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.error(StateError('private secret')),
          200,
        ),
      ),
    );
    addTearDown(loader.close);
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.network),
    );
  });

  test('close cancels in-flight load and rejects subsequent calls', () async {
    final started = Completer<void>();
    final loader = SubscriptionLoader(
      client: MockClient.streaming((request, _) async {
        started.complete();
        await (request as http.Abortable).abortTrigger!;
        throw http.RequestAbortedException(request.url);
      }),
    );
    final result = expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.closed),
    );
    await started.future;
    loader.close();
    loader.close();
    await result;
    await expectLater(
      loader.load(_url),
      failsWith(SubscriptionLoadErrorCode.closed),
    );
  });
}
