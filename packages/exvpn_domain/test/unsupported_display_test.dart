import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

void main() {
  const parser = SubscriptionParser();

  test('unsupported URI retains only its name and known protocol label', () {
    final result = parser.parse(
      'tuic://synthetic-secret@private.invalid:443?token=secret#🇯🇵%20Токио',
    );
    expect(result.profiles, isEmpty);
    final issue = result.issues.single;
    expect(issue.isUnsupportedConnection, isTrue);
    expect(issue.displayName, '🇯🇵 Токио');
    expect(issue.protocolLabel, 'TUIC');
    expect(issue.toString(), isNot(contains('secret')));
    expect(issue.toString(), isNot(contains('Токио')));
  });

  test('unsupported feature and base64 VMess keep cosmetic metadata only', () {
    final result = parser.parse(
      'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?type=quic#Berlin',
    );
    expect(result.profiles, isEmpty);
    expect(result.issues.single.displayName, 'Berlin');
    expect(result.issues.single.protocolLabel, 'VLESS · QUIC');
    final vmess = base64.encode(
      utf8.encode(
        jsonEncode({
          'ps': 'VMess preview',
          'add': 'private.invalid',
          'port': 443,
          'id': '00000000-0000-4000-8000-000000000001',
          'net': 'quic',
        }),
      ),
    );
    final issue = parser.parse('vmess://$vmess').issues.single;
    expect(issue.displayName, 'VMess preview');
    expect(issue.protocolLabel, 'VMess · QUIC');
  });

  test('JSON and encoded subscriptions expose no raw endpoint fields', () {
    final raw = jsonEncode({
      'outbounds': [
        {
          'type': 'tuic',
          'tag': 'Paris',
          'server': 'private.invalid',
          'password': 'synthetic-secret',
          'server_port': 443,
        },
      ],
    });
    final issue = parser.parse(raw).issues.single;
    expect(issue.displayName, 'Paris');
    expect(issue.protocolLabel, 'TUIC');
    final encoded = base64.encode(
      utf8.encode('tuic://secret@node.invalid:443#Tokyo'),
    );
    expect(parser.parse(encoded).issues.single.displayName, 'Tokyo');
  });

  test('malformed records are not displayed as unsupported connections', () {
    for (final raw in [
      'vless://bad@sample.invalid:443',
      '{"outbounds":[null]}',
    ]) {
      final issue = parser.parse(raw).issues.single;
      expect(issue.isUnsupportedConnection, isFalse);
      expect(issue.displayName, isNull);
    }
    final unsafe = parser
        .parse(
          'tuic://secret@node.invalid:443#https%3A%2F%2Fprivate.invalid%2Ftoken',
        )
        .issues
        .single;
    expect(unsafe.displayName, isNull);
    final bounded = parser
        .parse('tuic://secret@node.invalid:443#${'A' * 100}')
        .issues
        .single;
    expect(bounded.displayName, isNull);
  });
}
