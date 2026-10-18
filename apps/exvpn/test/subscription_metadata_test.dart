import 'dart:convert';

import 'package:exvpn/services/subscription_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _node =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Node';

void main() {
  test(
    'profile-title headers support UTF-8 base64 and outrank body names',
    () async {
      const body = '#profile-title: Body name\n$_node';
      final loader = SubscriptionLoader(
        client: MockClient(
          (_) async => http.Response(
            body,
            200,
            headers: {
              'profile-title':
                  'base64:${base64.encode(utf8.encode('Моя подписка'))}',
            },
          ),
        ),
      );
      addTearDown(loader.close);
      final document = await loader.loadDocument(
        'https://sample.invalid/private',
      );
      expect(document.providerName, 'Моя подписка');
      expect(document.body, body);
      expect(document.toString(), isNot(contains('private')));
      expect(await loader.load('https://sample.invalid/private'), body);
    },
  );

  test('body comments survive plain and base64 subscription import intact', () {
    const body = '#profile-title: North VPN\n$_node';
    expect(SubscriptionDocument.fromText(body).providerName, 'North VPN');
    final encoded = base64.encode(utf8.encode(body));
    final document = SubscriptionDocument.fromText(encoded);
    expect(document.providerName, 'North VPN');
    expect(document.body, encoded);
  });

  test('JSON metadata is allowed only on an outbound document root', () {
    for (final key in ['profile-title', 'remarks', 'name']) {
      final body = jsonEncode({key: 'JSON provider', 'outbounds': []});
      expect(SubscriptionDocument.fromText(body).providerName, 'JSON provider');
    }
    for (final body in [
      '{"name":"Not a subscription"}',
      '{"outbounds":[],"name":17}',
      '${List.filled(35, '[').join()}${List.filled(35, ']').join()}',
      '{"name":"Broken",',
    ]) {
      expect(SubscriptionDocument.fromText(body).providerName, isNull);
    }
  });

  test('Content-Disposition handles RFC5987 and quoted filenames safely', () {
    expect(
      SubscriptionDocument.fromText(
        _node,
        headers: {
          'Content-Disposition': "attachment; filename=plain.txt; filename*=UTF-8''%D0%A1%D0%B5%D0%B2%D0%B5%D1%80.txt",
        },
      ).providerName,
      'Север',
    );
    expect(
      SubscriptionDocument.fromText(
        _node,
        headers: {
          'content-disposition': 'attachment; filename="Example VPN.json"',
        },
      ).providerName,
      'Example VPN',
    );
    expect(
      SubscriptionDocument.fromText(
        _node,
        headers: {
          'profile-title': 'base64:!invalid',
          'content-disposition': 'attachment; filename="Fallback.txt"',
        },
      ).providerName,
      'Fallback',
    );
  });

  test('malicious names are ignored without exposing subscription addresses', () {
    for (final value in [
      'https://sample.invalid/private',
      'base64:${base64.encode(utf8.encode('https://sample.invalid/private'))}',
      'vless://private',
      '../private',
    ]) {
      final document = SubscriptionDocument.fromText(
        _node,
        headers: {'profile-title': value},
      );
      expect(document.providerName, isNull);
    }
    final document = SubscriptionDocument.fromText(
      _node,
      headers: {'profile-title': '\u202eNorth\u200b VPN\r\n'},
    );
    expect(document.providerName, 'North VPN');
  });
}
