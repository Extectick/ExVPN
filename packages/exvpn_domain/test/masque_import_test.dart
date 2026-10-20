import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

Map<String, dynamic> profile() => {
  'tag': 'Synthetic MASQUE',
  'protocol': 'masque',
  'settings': {'address': 'node.example', 'port': 443},
  'streamSettings': {
    'network': 'masque',
    'security': 'tls',
    'tlsSettings': {
      'serverName': 'masque.example',
      'alpn': ['h3'],
    },
    'masqueSettings': <String, dynamic>{
      'user': 'synthetic@example.invalid',
      'pass': 'synthetic-password',
    },
  },
};
ImportResult parse(Map<String, dynamic> value) =>
    const SubscriptionParser().parse(
      jsonEncode({
        'outbounds': [value],
      }),
    );
void main() {
  test(
    'Xray MASQUE default CONNECT-IP projects into strict existing native fields',
    () {
      final r = parse(profile());
      expect(r.issues, isEmpty);
      final p = r.profiles.single;
      expect(p.protocol, ProxyProtocol.masque);
      expect(p.transport.type, 'masque');
      expect(p.toNativeJson()['protocol'], 'masque');
      expect(p.toNativeJson()['username'], 'synthetic@example.invalid');
      expect(p.toNativeJson()['transport'], {'type': 'masque'});
      expect(p.tls.alpn, ['h3']);
      expect(p.tls.serverName, 'masque.example');
      expect(p.toString(), isNot(contains('synthetic-password')));
      final defaultAlpn = profile();
      defaultAlpn['streamSettings']['tlsSettings'].remove('alpn');
      expect(parse(defaultAlpn).profiles.single.tls.alpn, isEmpty);
    },
  );
  test('MASQUE requires authenticated TLS and bounded credentials', () {
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (p) => p['streamSettings']['security'] = 'none',
      (p) => p['streamSettings']['network'] = 'tcp',
      (p) => p['streamSettings']['tlsSettings'].remove('serverName'),
      (p) => p['streamSettings']['tlsSettings']['serverName'] = '',
      (p) => p['streamSettings']['tlsSettings']['serverName'] = 'bad host',
      (p) => p['streamSettings']['tlsSettings']['allowInsecure'] = true,
      (p) => p['streamSettings']['tlsSettings']['allowInsecure'] = 'false',
      (p) => p['streamSettings']['tlsSettings']['alpn'] = ['h2'],
      (p) => p['streamSettings']['tlsSettings']['alpn'] = ['h3', 'h3'],
      (p) => p['streamSettings']['tlsSettings']['alpn'] = 'h3',
      (p) => p['streamSettings']['tlsSettings']['fingerprint'] = 'chrome',
      (p) => p['streamSettings']['tlsSettings']['certificateFile'] =
          'provider.pem',
      (p) =>
          p['streamSettings']['realitySettings'] = {'publicKey': 'not-masque'},
      (p) => p['streamSettings']['masqueSettings']['user'] = '',
      (p) => p['streamSettings']['masqueSettings']['user'] = 'bad:user',
      (p) => p['streamSettings']['masqueSettings']['user'] = 'bad\r\nUser',
      (p) => p['streamSettings']['masqueSettings']['user'] = 'a' * 256,
      (p) => p['streamSettings']['masqueSettings']['pass'] = '',
      (p) => p['streamSettings']['masqueSettings']['pass'] = 'bad\nPassword',
      (p) => p['streamSettings']['masqueSettings']['pass'] = 'a' * 256,
      (p) => p['streamSettings']['masqueSettings']['pass'] = 24,
      (p) => p['settings']['port'] = '443',
    ]) {
      final value = profile();
      mutation(value);
      final result = parse(value);
      expect(result.profiles, isEmpty);
      expect(result.issues, isNotEmpty);
      expect(result.issues.toString(), isNot(contains('synthetic-password')));
    }
  });
  test(
    'MASQUE provider cannot assign DNS custom transport authority or unsupported format',
    () {
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (p) => p['settings']['remoteDNS'] = ['8.8.8.8'],
        (p) =>
            p['streamSettings']['masqueSettings']['host'] = 'another.example',
        (p) => p['streamSettings']['masqueSettings']['path'] = '/custom',
        (p) => p['streamSettings']['masqueSettings']['headers'] = {
          'Authorization': 'x',
        },
        (p) => p['streamSettings']['masqueSettings']['warp'] = true,
        (p) => p['streamSettings']['sockopt'] = {'interface': 'provider'},
      ]) {
        final value = profile();
        mutation(value);
        expect(parse(value).profiles, isEmpty);
      }
      expect(
        const SubscriptionParser()
            .parse('masque://user:password@node.example:443')
            .profiles,
        isEmpty,
      );
      expect(
        parse({
          'type': 'masque',
          'server': 'node.example',
          'server_port': 443,
          'username': 'x',
          'password': 'y',
        }).profiles,
        isEmpty,
      );
    },
  );
}
