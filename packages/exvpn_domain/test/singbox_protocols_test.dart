import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const uuid = '123e4567-e89b-12d3-a456-426614174000';
Map<String, dynamic> profile(String type) => {
  'type': type,
  'tag': 'Synthetic',
  'server': 'node.example',
  'server_port': 443,
  if (type == 'vmess') 'uuid': uuid else 'password': 'synthetic-password',
  if (type == 'shadowsocks') 'method': 'aes-128-gcm',
  'tls': {'enabled': true, 'server_name': 'front.example'},
};
ImportResult parse(Map<String, dynamic> value) =>
    const SubscriptionParser().parse(
      jsonEncode({
        'outbounds': [value],
      }),
    );
void main() {
  test(
    'sing-box popular protocols normalize into the existing core contract',
    () {
      for (final type in ['vmess', 'trojan', 'shadowsocks']) {
        final r = parse(profile(type));
        expect(r.issues, isEmpty);
        final p = r.profiles.single;
        expect(p.protocol.name, type);
        expect(p.tls.enabled, isTrue);
        expect(p.tls.serverName, 'front.example');
        if (type == 'vmess') {
          expect(p.uuid, uuid);
          expect(p.cipher, 'auto');
        } else {
          expect(p.password, 'synthetic-password');
        }
        if (type == 'shadowsocks') expect(p.cipher, 'aes-128-gcm');
      }
    },
  );
  test('sing-box grpc normalizes service name for VMess VLESS and Trojan', () {
    for (final type in ['vmess', 'vless', 'trojan']) {
      final v = profile(type);
      if (type == 'vless') {
        v.remove('password');
        v['uuid'] = uuid;
      }
      v['transport'] = {'type': 'grpc', 'service_name': 'example-service'};
      final p = parse(v).profiles.single;
      expect(p.transport.type, 'grpc');
      expect(p.transport.serviceName, 'example-service');
      expect(
        p.toNativeJson()['transport'],
        containsPair('serviceName', 'example-service'),
      );
    }
  });
  test(
    'sing-box common protocol options remain strict and security is preserved',
    () {
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (p) => p['tls'] = {'enabled': false},
        (p) => p['tls']['insecure'] = true,
        (p) => p['detour'] = 'direct',
        (p) => p['flow'] = 'xtls-rprx-vision',
        (p) => p['transport'] = {
          'type': 'grpc',
          'service_name': 'x',
          'path': '/bad',
        },
        (p) => p['transport'] = {'type': 'ws', 'service_name': 'not-ws'},
      ]) {
        final v = profile('trojan');
        mutation(v);
        expect(parse(v).profiles, isEmpty);
      }
      for (final bad in [1, '0', true, 0.5]) {
        expect(parse(profile('vmess')..['alter_id'] = bad).profiles, isEmpty);
      }
      for (final flag in ['global_padding', 'authenticated_length']) {
        expect(parse(profile('vmess')..[flag] = true).profiles, isEmpty);
        expect(parse(profile('vmess')..[flag] = false).profiles.length, 1);
      }
      for (final type in ['vmess', 'trojan', 'shadowsocks']) {
        expect(parse(profile(type)..['method'] = 'none').profiles, isEmpty);
      }
      expect(parse(profile('vmess')..['security'] = 'none').profiles, isEmpty);
      expect(
        parse(
          profile('shadowsocks')..['method'] = 'unsupported-cipher',
        ).profiles,
        isEmpty,
      );
    },
  );
}
