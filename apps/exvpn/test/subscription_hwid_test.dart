import 'dart:async';

import 'package:exvpn/services/subscription_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _url = 'https://provider.example/sub/private-token';
const _identity = '12345678-1234-4234-8234-123456789abc';
const _required = {
  'x-hwid-active': 'true',
  'x-hwid-not-supported': 'true',
  'x-hwid-limit': 'true',
};
Matcher _fails(SubscriptionLoadErrorCode code) => throwsA(
  isA<SubscriptionLoadException>().having((e) => e.code, 'code', code),
);

void main() {
  for (final status in [200, 404]) {
    test(
      'HWID challenge $status replaces placeholder with one bounded retry',
      () async {
        var requests = 0;
        var identities = 0;
        final loader = SubscriptionLoader(
          identity: (uri) async {
            identities++;
            expect(uri.toString(), _url);
            return _identity;
          },
          client: MockClient((request) async {
            requests++;
            expect(request.headers['user-agent'], startsWith('ExVPN/'));
            expect(request.followRedirects, isFalse);
            expect(request.url.toString(), _url);
            if (requests == 1) {
              expect(request.headers.containsKey('x-hwid'), isFalse);
              return http.Response(
                'valid-looking placeholder',
                status,
                headers: _required,
              );
            }
            expect(request.headers['x-hwid'], _identity);
            return http.Response('actual subscription', 200);
          }),
        );
        addTearDown(loader.close);
        expect(await loader.load(_url), 'actual subscription');
        expect(requests, 2);
        expect(identities, 1);
      },
    );
  }
  test('normal providers receive no device identity', () async {
    final loader = SubscriptionLoader(
      identity: (_) async => throw StateError('must not be called'),
      client: MockClient((r) async {
        expect(r.headers.containsKey('x-hwid'), isFalse);
        return http.Response('ordinary', 200);
      }),
    );
    addTearDown(loader.close);
    expect(await loader.load(_url), 'ordinary');
  });
  for (final headers in [
    {'x-hwid-max-devices-reached': 'true'},
    {'x-hwid-limit': 'true'},
    {..._required, 'x-hwid-max-devices-reached': 'true'},
  ]) {
    test(
      'device limit is reported without retry or body import: ${headers.keys}',
      () async {
        var requests = 0;
        final loader = SubscriptionLoader(
          identity: (_) async =>
              throw StateError('must not register another identity'),
          client: MockClient((_) async {
            requests++;
            return http.Response('placeholder', 200, headers: headers);
          }),
        );
        addTearDown(loader.close);
        await expectLater(
          loader.load(_url),
          _fails(SubscriptionLoadErrorCode.deviceLimitReached),
        );
        expect(requests, 1);
      },
    );
  }
  test('second rejection stops without rotating or looping', () async {
    var requests = 0;
    final loader = SubscriptionLoader(
      identity: (_) async => _identity,
      client: MockClient((_) async {
        requests++;
        return http.Response('placeholder', 200, headers: _required);
      }),
    );
    addTearDown(loader.close);
    await expectLater(
      loader.load(_url),
      _fails(SubscriptionLoadErrorCode.deviceIdentityRejected),
    );
    expect(requests, 2);
  });
  for (final invalid in ['short', 'private\r\nInjected: secret']) {
    test(
      'invalid identity never reaches headers (${invalid.length})',
      () async {
        var requests = 0;
        final loader = SubscriptionLoader(
          identity: (_) async => invalid,
          client: MockClient((_) async {
            requests++;
            return http.Response('', 404, headers: _required);
          }),
        );
        addTearDown(loader.close);
        await expectLater(
          loader.load(_url),
          _fails(SubscriptionLoadErrorCode.deviceIdentityUnavailable),
        );
        expect(requests, 1);
      },
    );
  }
  test(
    'redirect challenge cannot disclose identity to another origin',
    () async {
      var identities = 0;
      final loader = SubscriptionLoader(
        identity: (_) async {
          identities++;
          return _identity;
        },
        client: MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {..._required, 'location': 'https://other.example'},
          ),
        ),
      );
      addTearDown(loader.close);
      await expectLater(
        loader.load(_url),
        _fails(SubscriptionLoadErrorCode.redirect),
      );
      expect(identities, 0);
    },
  );
  for (final close in [false, true]) {
    test(
      'pending identity obeys ${close ? 'close' : 'the original deadline'}',
      () async {
        final identity = Completer<String>();
        final requested = Completer<void>();
        var requests = 0;
        final loader = SubscriptionLoader(
          timeout: const Duration(milliseconds: 60),
          identity: (_) {
            requested.complete();
            return identity.future;
          },
          client: MockClient((_) async {
            requests++;
            return http.Response('', 404, headers: _required);
          }),
        );
        addTearDown(loader.close);
        final operation = expectLater(
          loader.load(_url),
          _fails(
            close
                ? SubscriptionLoadErrorCode.closed
                : SubscriptionLoadErrorCode.timeout,
          ),
        );
        await requested.future;
        if (close) loader.close();
        await operation;
        identity.complete(_identity);
        await Future<void>.delayed(Duration.zero);
        expect(requests, 1);
      },
    );
  }
}
