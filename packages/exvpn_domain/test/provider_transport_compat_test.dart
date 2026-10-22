// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const uuid = '123e4567-e89b-12d3-a456-426614174000';
final key = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
const tuning = {
  'congestion': 'bbr',
  'maxIdleTimeout': 10,
  'keepAlivePeriod': 5,
  'maxStreamReceiveWindow': 8388608,
  'initStreamReceiveWindow': 8388608,
  'maxConnectionReceiveWindow': 20971520,
  'initConnectionReceiveWindow': 20971520,
};
String hy2(Object mask) => Uri(
  scheme: 'hysteria2',
  userInfo: 'synthetic-password',
  host: 'node.example',
  port: 443,
  queryParameters: {'sni': 'front.example', 'fm': jsonEncode(mask)},
  fragment: 'Example',
).toString();
ConnectionProfile single(String input) {
  final result = const SubscriptionParser().parse(input);
  expect(result.issues, isEmpty);
  return result.profiles.single;
}

void rejected(String input) {
  final result = const SubscriptionParser().parse(input);
  expect(result.profiles, isEmpty);
  expect(result.issues, isNotEmpty);
  expect(result.issues.toString(), isNot(contains('synthetic-password')));
}

void main() {
  test(
    'explicit TCP none header preserves REALITY Vision and profile identity',
    () {
      final bare =
          'vless://$uuid@node.example:443?security=reality&sni=front.example'
          '&fp=edge&pbk=$key&sid=&spx=%2F&flow=xtls-rprx-vision&encryption=none&type=tcp';
      final original = single(bare);
      final imported = single('$bare&headerType=none');
      expect(imported.toNativeJson(), original.toNativeJson());
      expect(
        imported.id,
        single(
          '${bare.replaceFirst('type=tcp', 'type=raw')}&headerType=none',
        ).id,
      );
      expect(imported.tls.fingerprint, 'edge');
      expect(imported.tls.reality!.publicKey, key);
      expect(imported.flow, 'xtls-rprx-vision');
      for (final suffix in [
        '&headerType=http',
        '&headerType=',
        '&headerType=none&headerType=http',
      ]) {
        rejected('$bare$suffix');
      }
      rejected('${bare.replaceFirst('type=tcp', 'type=grpc')}&headerType=none');
    },
  );

  test('Hysteria2 URI carries exact QUIC tuning and keeps TLS mandatory', () {
    final profile = single(
      hy2({
        'quicParams': {'debug': false, ...tuning},
      }),
    );
    expect(profile.transport.quicParams!.toJson(), tuning);
    expect(profile.tls.enabled, isTrue);
    expect(profile.tls.serverName, 'front.example');
    expect(profile.id, single(hy2({'quicParams': tuning})).id);
    expect(
      single(
        hy2({
          'quicParams': {'debug': false, 'congestion': 'bbr'},
        }),
      ).transport.quicParams!.toJson(),
      {'congestion': 'bbr'},
    );
    rejected('${hy2({'quicParams': tuning}).split('#').first}&security=none');
  });

  test('base64 subscription and Xray JSON use the same bounded adapter', () {
    final uri = hy2({'quicParams': tuning});
    expect(single(base64Encode(utf8.encode(uri))).id, single(uri).id);
    final profile = single(
      jsonEncode({
        'outbounds': [
          {
            'protocol': 'hysteria',
            'tag': 'Example',
            'settings': {'version': 2, 'address': 'node.example', 'port': 443},
            'streamSettings': {
              'network': 'hysteria',
              'security': 'tls',
              'tlsSettings': {'serverName': 'front.example'},
              'hysteriaSettings': {'version': 2, 'auth': 'synthetic-password'},
              'finalmask': {'quicParams': tuning},
            },
          },
        ],
      }),
    );
    expect(profile.toNativeJson(), single(uri).toNativeJson());
  });

  test('QUIC tuning cannot introduce masks, routes, logs or TLS bypass', () {
    for (final mask in [
      {
        'quicParams': {...tuning, 'debug': true},
      },
      {
        'quicParams': {...tuning, 'debug': 'false'},
      },
      {
        'quicParams': {...tuning, 'allowInsecure': true},
      },
      {
        'quicParams': {...tuning, 'congestion': 'unknown'},
      },
      {
        'quicParams': {...tuning, 'congestion': 'force-brutal'},
      },
      {'quicParams': tuning, 'tcp': <Object?>[]},
      {'quicParams': tuning, 'udp': <Object?>[]},
      {'quicParams': tuning, 'routing': <String, Object?>{}},
      {'quicParams': null},
    ]) {
      rejected(hy2(mask));
    }
    for (final entry in <String, Object?>{
      'maxIdleTimeout': 121,
      'keepAlivePeriod': 10,
      'initStreamReceiveWindow': 16777217,
      'maxConnectionReceiveWindow': 67108865,
      'initConnectionReceiveWindow': 16777216,
    }.entries) {
      final values = {...tuning, entry.key: entry.value};
      if (entry.key == 'initConnectionReceiveWindow') {
        values['maxConnectionReceiveWindow'] = 8388608;
      }
      rejected(hy2({'quicParams': values}));
    }
    for (final bad in [null, -1, 16383, '8388608', 8388608.5, true]) {
      rejected(
        hy2({
          'quicParams': {...tuning, 'maxStreamReceiveWindow': bad},
        }),
      );
    }
  });

  test(
    'native-normalized QUIC model is immutable and validates all callers',
    () {
      final input = Map<String, Object?>.of(tuning);
      final model = QuicOptions.fromJson(input);
      input['congestion'] = 'unknown';
      final exported = model.toJson()..['congestion'] = 'unknown';
      expect(exported, isNot(model.toJson()));
      expect(model.toJson(), tuning);
      expect(
        QuicOptions.fromJson({
          'maxIdleTimeout': 0,
          'keepAlivePeriod': 0,
        }).toJson(),
        isEmpty,
      );
      expect(
        () => QuicOptions.fromJson({'debug': false}),
        throwsFormatException,
      );
      expect(
        () => QuicOptions.fromJson({'congestion': null}),
        throwsFormatException,
      );
    },
  );
}
