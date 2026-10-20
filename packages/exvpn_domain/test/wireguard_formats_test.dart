import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

final privateKey = base64.encode(List.filled(32, 251));
final publicKey = base64.encode(List.filled(32, 7));
final psk = base64.encode(List.filled(32, 11));
String link({
  String scheme = 'wireguard',
  Map<String, String> query = const {},
  String? secret,
  String host = 'node.example',
}) => Uri(
  scheme: scheme,
  userInfo: Uri.encodeComponent(secret ?? privateKey),
  host: host,
  port: 51820,
  queryParameters: {
    'publickey': publicKey,
    'address': '10.7.0.2/32,fd00:7::2/128',
    ...query,
  },
  fragment: 'Synthetic WG',
).toString();
ImportResult parse(String text) => const SubscriptionParser().parse(text);
Map<String, dynamic> endpoint() => {
  'type': 'wireguard',
  'tag': 'Synthetic WG',
  'system': false,
  'address': ['10.7.0.2/32', 'fd00:7::2/128'],
  'private_key': privateKey,
  'peers': <Map<String, dynamic>>[
    <String, dynamic>{
      'address': 'node.example',
      'port': 51820,
      'public_key': publicKey,
      'pre_shared_key': psk,
      'allowed_ips': ['0.0.0.0/0', '::/0'],
      'persistent_keepalive_interval': 25,
      'reserved': [1, 2, 3],
    },
  ],
};
ImportResult parseEndpoint(Map<String, dynamic> value) => parse(
  jsonEncode({
    'endpoints': [value],
  }),
);
void main() {
  test(
    'legacy Xray and sing-box WireGuard reserve bytes normalize from base64',
    () {
      final xray = {
        'protocol': 'wireguard',
        'settings': {
          'secretKey': privateKey,
          'address': ['10.7.0.2/32'],
          'reserved': 'AQID',
          'peers': [
            {'publicKey': publicKey, 'endpoint': 'node.example:51820'},
          ],
        },
      };
      final sing = {
        'type': 'wireguard',
        'server': 'node.example',
        'server_port': 51820,
        'private_key': privateKey,
        'peer_public_key': publicKey,
        'local_address': ['10.7.0.2/32'],
        'reserved': 'AQID',
      };
      for (final node in [xray, sing]) {
        final r = parse(
          jsonEncode({
            'outbounds': [node],
          }),
        );
        expect(r.issues, isEmpty);
        expect(r.profiles.single.wireguard!.reserved, [1, 2, 3]);
      }
    },
  );
  test(
    'WireGuard links decode secrets once and preserve typed optional fields',
    () {
      for (final scheme in ['wireguard', 'wg']) {
        final r = parse(
          link(
            scheme: scheme,
            query: {
              'presharedkey': psk,
              'mtu': '1408',
              'keepalive': '25',
              'reserved': '1,2,3',
            },
          ),
        );
        expect(r.issues, isEmpty);
        final p = r.profiles.single;
        expect(p.protocol, ProxyProtocol.wireguard);
        expect(p.wireguard!.privateKey, privateKey);
        expect(p.wireguard!.preSharedKey, psk);
        expect(p.wireguard!.mtu, 1408);
        expect(p.wireguard!.keepAlive, 25);
        expect(p.wireguard!.reserved, [1, 2, 3]);
        expect(p.wireguard!.addresses, ['10.7.0.2/32', 'fd00:7::2/128']);
        expect(p.toString(), isNot(contains(privateKey)));
      }
      expect(
        parse(link(host: '2001:db8::1')).profiles.single.server,
        '2001:db8::1',
      );
      expect(
        parse(link(secret: Uri.encodeComponent(privateKey))).profiles,
        isEmpty,
      );
    },
  );
  test('WireGuard link reserved base64 has exact three-byte identity', () {
    expect(
      parse(link(query: {'reserved': 'AQID'})).profiles.single.id,
      parse(link(query: {'reserved': '1,2,3'})).profiles.single.id,
    );
    for (final value in [
      'AQI=',
      'AQIDBA==',
      '1,2,256',
      '1,2,-1',
      '1,2,3,4',
      '1.5,2,3',
    ]) {
      expect(parse(link(query: {'reserved': value})).profiles, isEmpty);
    }
  });
  test(
    'WireGuard links reject ambiguous fields, unsafe routing and wrong key values',
    () {
      for (final query in <Map<String, String>>[
        {'publickey': 'not-a-key'},
        {'presharedkey': ''},
        {'address': '0.0.0.0/0'},
        {'address': '10.7.0.2/32,10.7.0.2/32'},
        {'mtu': '9000'},
        {'mtu': '1280.0'},
        {'keepalive': '121'},
        {'keepalive': 'true'},
        {'dns': '1.1.1.1'},
        {'allowedips': '10.0.0.0/8'},
        {'interface': 'owned-by-provider'},
        {'fm': 'not-supported'},
        {'endpoint': 'another.example:51820'},
      ]) {
        expect(parse(link(query: query)).profiles, isEmpty);
      }
      expect(
        parse(
          '${link()}&publickey=${Uri.encodeQueryComponent(publicKey)}',
        ).profiles,
        isNotEmpty,
      );
      // Duplicate is in query, before the fragment rather than part of its name.
      final original = link();
      final duplicate = original.replaceFirst(
        '#',
        '&publickey=${Uri.encodeQueryComponent(publicKey)}#',
      );
      expect(parse(duplicate).profiles, isEmpty);
      expect(
        parse(link().replaceFirst(':51820', ':51820/unexpected')).profiles,
        isEmpty,
      );
      expect(parse(link().replaceFirst(':51820', '')).profiles, isEmpty);
    },
  );
  test(
    'current sing-box WireGuard endpoint normalizes to existing native schema',
    () {
      final r = parseEndpoint(endpoint());
      expect(r.issues, isEmpty);
      final p = r.profiles.single;
      expect(p.protocol, ProxyProtocol.wireguard);
      expect(p.wireguard!.mtu, 1408);
      expect(p.wireguard!.keepAlive, 25);
      expect(p.wireguard!.reserved, [1, 2, 3]);
      expect(
        p.toNativeJson()['wireguard'],
        containsPair('publicKey', publicKey),
      );
      final same = endpoint()..['address'] = '10.7.0.2/32';
      same['peers'] = (same['peers'] as List).single;
      expect(parseEndpoint(same).profiles.single.wireguard!.addresses, [
        '10.7.0.2/32',
      ]);
      final encoded = endpoint();
      encoded['peers'][0]['reserved'] = 'AQID';
      expect(parseEndpoint(encoded).profiles.single.id, p.id);
    },
  );
  test(
    'WireGuard endpoint never admits OS interfaces listeners multiple peers or provider routes',
    () {
      for (final entry in <String, Object?>{
        'system': true,
        'name': 'wg-custom',
        'listen_port': 51820,
        'listen_port_bad_type': 0.0,
        'workers': 4,
        'on_demand': true,
        'detour': 'direct',
        'bind_interface': 'eth0',
        'route': {},
      }.entries) {
        final v = endpoint();
        v[entry.key == 'listen_port_bad_type' ? 'listen_port' : entry.key] =
            entry.value;
        expect(parseEndpoint(v).profiles, isEmpty, reason: entry.key);
      }
      final two = endpoint();
      two['peers'].add(Map<String, Object>.from(two['peers'][0] as Map));
      expect(parseEndpoint(two).profiles, isEmpty);
      for (final fields in <Map<String, Object?>>[
        {
          'allowed_ips': ['10.0.0.0/8'],
        },
        {'allowed_ips': []},
        {'persistent_keepalive_interval': '25'},
        {
          'reserved': [1, 2, 256],
        },
        {'port': 1.5},
        {'detour': 'direct'},
        {'address': '0.0.0.0'},
      ]) {
        final v = endpoint();
        v['peers'][0].addAll(fields);
        expect(parseEndpoint(v).profiles, isEmpty);
      }
    },
  );
  test(
    'endpoint and outbound records share bounded import without index collisions',
    () {
      final v = endpoint();
      final r = parse(
        jsonEncode({
          'outbounds': [
            {'type': 'unknown'},
          ],
          'endpoints': [v],
        }),
      );
      expect(r.profiles.length, 1);
      expect(r.issues.single.index, 1);
      final bad = endpoint()..['system'] = true;
      final both = parse(
        jsonEncode({
          'outbounds': [
            {'type': 'unknown'},
          ],
          'endpoints': [bad],
        }),
      );
      expect(both.issues.map((e) => e.index), [1, 2]);
      expect(
        const SubscriptionParser(maxProfiles: 1)
            .parse(
              jsonEncode({
                'outbounds': [<String, Object?>{}],
                'endpoints': [v],
              }),
            )
            .issues
            .single
            .code,
        ImportIssueCode.tooManyProfiles,
      );
      expect(
        parse(
          jsonEncode({
            'outbounds': <String, Object?>{},
            'endpoints': [v],
          }),
        ).profiles,
        isEmpty,
      );
      expect(
        parse(
          jsonEncode({
            'endpoints': [v],
            'route': {'final': 'direct'},
          }),
        ).issues.single.code,
        ImportIssueCode.ignoredLocalConfiguration,
      );
    },
  );
}
