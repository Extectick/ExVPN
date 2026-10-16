import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const _uuid = '123e4567-e89b-12d3-a456-426614174000';
const _server = 'node.example';
final _publicKey = base64Url
    .encode(List<int>.filled(32, 1))
    .replaceAll('=', '');

String _vless({
  String query = 'security=tls&sni=front.example',
  String name = 'Node',
  String host = _server,
}) => 'vless://$_uuid@$host:443?$query#${Uri.encodeComponent(name)}';

String _encodedJson(Object value) =>
    base64.encode(utf8.encode(jsonEncode(value)));

Map<String, Object?> _vmessFields() => {
  'v': '2',
  'ps': 'VMess',
  'add': _server,
  'port': '443',
  'id': _uuid,
  'aid': '0',
  'scy': 'auto',
  'net': 'ws',
  'type': 'none',
  'host': 'front.example',
  'path': '/ws',
  'tls': 'tls',
  'sni': 'front.example',
};

Map<String, Object?> _outbound({String protocol = 'vless'}) => {
  'tag': 'Node',
  'protocol': protocol,
  'settings': {
    'vnext': [
      {
        'address': _server,
        'port': 443,
        'users': [
          if (protocol == 'vless')
            {'id': _uuid, 'encryption': 'none'}
          else
            {'id': _uuid, 'security': 'auto', 'alterId': 0},
        ],
      },
    ],
  },
  'streamSettings': {
    'network': 'tcp',
    'security': 'tls',
    'tlsSettings': {'serverName': 'front.example'},
  },
};

ImportResult _jsonImport(Object outbound) => const SubscriptionParser().parse(
  jsonEncode({
    'outbounds': [outbound],
  }),
);

ConnectionProfile _single(String text) {
  final result = const SubscriptionParser().parse(text);
  expect(result.issues, isEmpty);
  expect(result.profiles, hasLength(1));
  return result.profiles.single;
}

void _rejected(String text, {ImportIssueCode? code}) {
  final result = const SubscriptionParser().parse(text);
  expect(result.profiles, isEmpty);
  expect(result.issues, isNotEmpty);
  if (code != null) expect(result.issues.first.code, code);
  final diagnostics = result.issues.toString();
  expect(diagnostics, isNot(contains(_uuid)));
  expect(diagnostics, isNot(contains(_server)));
  expect(diagnostics, isNot(contains('private-password')));
}

void main() {
  group('Supported URI profiles', () {
    test('VLESS REALITY TCP preserves security and flow', () {
      final p = _single(
        _vless(
          query:
              'security=reality&sni=front.example&fp=chrome&pbk=$_publicKey&sid=abcd&spx=%2F&flow=xtls-rprx-vision',
        ),
      );
      expect(p.protocol, ProxyProtocol.vless);
      expect(p.uuid, _uuid);
      expect(p.flow, 'xtls-rprx-vision');
      expect(p.tls.enabled, isTrue);
      expect(p.tls.reality!.publicKey, _publicKey);
      expect(p.tls.reality!.shortId, 'abcd');
      expect(p.tls.reality!.spiderX, '/');
    });

    test('XHTTP REALITY parameters survive normalization', () {
      final p = _single(
        _vless(
          query:
              'type=xhttp&security=reality&sni=front.example&pbk=$_publicKey&path=%2Ftunnel&host=front.example&mode=packet-up',
        ),
      );
      expect(p.transport.toJson(), {
        'type': 'xhttp',
        'path': '/tunnel',
        'host': 'front.example',
        'mode': 'packet-up',
      });
      expect(p.tls.reality, isNotNull);
    });

    test('WebSocket TLS and ALPN remain distinct from REALITY', () {
      final p = _single(
        _vless(
          query:
              'type=ws&security=tls&sni=front.example&path=%2Fws&host=front.example&alpn=h2%2Chttp%2F1.1',
        ),
      );
      expect(p.transport.type, 'ws');
      expect(p.tls.alpn, ['h2', 'http/1.1']);
      expect(p.tls.reality, isNull);
    });

    test('gRPC service is projected', () {
      final p = _single(
        _vless(query: 'type=grpc&security=tls&serviceName=service'),
      );
      expect(p.transport.serviceName, 'service');
    });

    test('raw transport normalizes to tcp', () {
      expect(
        _single(_vless(query: 'type=raw&security=none')).transport.type,
        'tcp',
      );
    });

    test('VMess Base64 JSON accepts conventional numeric strings', () {
      final p = _single('vmess://${_encodedJson(_vmessFields())}');
      expect(p.protocol, ProxyProtocol.vmess);
      expect(p.cipher, 'auto');
      expect(p.port, 443);
      expect(p.transport.path, '/ws');
    });

    test('Trojan password percent decoding occurs exactly once', () {
      final p = _single(
        'trojan://pa%252Fss%3Aword@$_server:443?sni=front.example#Trojan',
      );
      expect(p.password, 'pa%2Fss:word');
      expect(p.tls.enabled, isTrue);
    });

    test('Shadowsocks SIP002 unpadded Base64 userinfo', () {
      final auth = base64Url
          .encode(utf8.encode('aes-128-gcm:pa:ss@word'))
          .replaceAll('=', '');
      final p = _single('ss://$auth@$_server:8388/#SIP002');
      expect(p.cipher, 'aes-128-gcm');
      expect(p.password, 'pa:ss@word');
      expect(p.port, 8388);
    });

    test('Shadowsocks legacy entire URI Base64', () {
      final data = base64.encode(
        utf8.encode('aes-256-gcm:password@$_server:8388'),
      );
      final p = _single('ss://$data#Legacy');
      expect(p.name, 'Legacy');
      expect(p.server, _server);
      expect(p.password, 'password');
    });

    test('Shadowsocks cipher alias agrees with native schema', () {
      final p = _single('ss://chacha20-poly1305:password@$_server:8388');
      expect(p.cipher, 'chacha20-ietf-poly1305');
    });

    for (final scheme in ['hy2', 'hysteria2']) {
      test('$scheme supplies TLS and default UDP port', () {
        final p = _single('$scheme://password@$_server?sni=front.example');
        expect(p.protocol, ProxyProtocol.hysteria2);
        expect(p.port, 443);
        expect(p.transport.type, 'hysteria');
        expect(p.tls.enabled, isTrue);
      });
    }

    test('IPv6 host is emitted without brackets for native validation', () {
      final p = _single(_vless(host: '[2001:db8::1]'));
      expect(p.server, '2001:db8::1');
    });

    test(
      'names are decoded once, stripped of controls, rune and byte bounded',
      () {
        final p = _single(_vless(name: '\n${'🐿' * 120}%2F\u0000'));
        expect(p.name, isNot(contains('\n')));
        expect(p.name, isNot(contains('\u0000')));
        expect(utf8.encode(p.name).length, lessThanOrEqualTo(256));
        expect(p.name.runes.length, lessThanOrEqualTo(100));
        expect(_single(_vless(name: '%2F')).name, '%2F');
      },
    );
  });

  group('Subscription and identity boundaries', () {
    test('plain text, BOM, comments and CRLF', () {
      final input =
          '\uFEFF# comment\r\n${_vless()}\r\n\r\nhy2://password@other.example\r\n';
      final r = const SubscriptionParser().parse(input);
      expect(r.profiles, hasLength(2));
      expect(r.issues, isEmpty);
    });

    test('whole subscription Base64 with embedded whitespace', () {
      final encoded = base64.encode(
        utf8.encode('${_vless()}\nhy2://password@other.example'),
      );
      final r = const SubscriptionParser().parse(
        '${encoded.substring(0, 20)}\n${encoded.substring(20)}',
      );
      expect(r.profiles, hasLength(2));
      expect(r.issues, isEmpty);
    });

    test('name and query ordering do not change connection ID', () {
      final a = _single(_vless());
      final b = _single(
        _vless(name: 'Renamed', query: 'sni=front.example&security=tls'),
      );
      expect(a.id, b.id);
      final r = const SubscriptionParser().parse(
        '${_vless()}\n${_vless(name: 'Renamed')}',
      );
      expect(r.profiles, hasLength(1));
    });

    test('different password produces a different ID', () {
      final a = _single('trojan://one@$_server:443');
      final b = _single('trojan://two@$_server:443');
      expect(a.id, isNot(b.id));
    });

    test('partial invalid input preserves good records and line indices', () {
      final r = const SubscriptionParser().parse(
        '# comment\n${_vless()}\nvless://private-password@bad.example:443\nunknown://hidden',
      );
      expect(r.profiles, hasLength(1));
      expect(r.issues.map((i) => i.index), [3, 4]);
      expect(r.issues.toString(), isNot(contains('private-password')));
    });

    test('profile count excludes blank and comment lines', () {
      final r = const SubscriptionParser(
        maxProfiles: 1,
      ).parse('# A\n\n# B\n${_vless()}');
      expect(r.profiles, hasLength(1));
      expect(
        const SubscriptionParser(
          maxProfiles: 1,
        ).parse('${_vless()}\nhy2://p@other.example').issues.single.code,
        ImportIssueCode.tooManyProfiles,
      );
    });

    test('byte bound includes UTF-8 bytes before parsing', () {
      final r = const SubscriptionParser(maxBytes: 4).parse('🐿🐿');
      expect(r.issues.single.code, ImportIssueCode.tooLarge);
    });

    test('native JSON has only the normalized schema', () {
      final p = _single(_vless());
      final native = p.toNativeJson();
      expect(
        native.keys,
        unorderedEquals([
          'id',
          'name',
          'protocol',
          'server',
          'port',
          'uuid',
          'transport',
          'tls',
        ]),
      );
      expect(native.values, isNot(contains(null)));
      expect(p.toString(), 'ConnectionProfile(<redacted>)');
      expect(jsonEncode(native), contains(_uuid));
    });

    test('collections exposed by import and TLS are immutable', () {
      final r = const SubscriptionParser().parse(_vless());
      expect(() => r.profiles.clear(), throwsUnsupportedError);
      expect(() => r.issues.clear(), throwsUnsupportedError);
      expect(
        () => r.profiles.single.tls.alpn.add('h2'),
        throwsUnsupportedError,
      );
    });

    for (final text in [
      '',
      ' \n',
      '# only comments',
      base64.encode(utf8.encode(' ')),
      '{"outbounds":[]}',
    ]) {
      test('empty document is diagnosed: ${text.length} characters', () {
        final r = const SubscriptionParser().parse(text);
        expect(r.profiles, isEmpty);
        expect(r.issues, isNotEmpty);
      });
    }
  });

  group('Rejected URI semantics', () {
    final badQueries = {
      'unknown': 'security=tls&unknown=1',
      'unknown empty': 'security=tls&unknown=',
      'unsafe TLS': 'security=tls&allowInsecure=1',
      'duplicate security': 'security=tls&security=none',
      'encryption': 'encryption=unsupported',
      'security mismatch': 'security=none&sni=front.example',
      'fingerprint mismatch': 'security=none&fp=chrome',
      'bad fingerprint': 'security=tls&fp=unsupported',
      'conflicting server names':
          'security=tls&sni=one.example&peer=two.example',
      'irrelevant HTTP path': 'type=tcp&path=%2Fhidden',
      'irrelevant gRPC service': 'type=ws&serviceName=hidden',
      'irrelevant XHTTP mode': 'type=ws&mode=auto',
      'invalid path': 'type=ws&path=not-absolute',
      'invalid mode': 'type=xhttp&mode=bad',
      'header injection': 'type=ws&host=front.example%0D%0AInjected',
      'REALITY bad key': 'security=reality&sni=front.example&pbk=bad',
      'REALITY odd short ID':
          'security=reality&sni=front.example&pbk=$_publicKey&sid=a',
      'REALITY nonhex ID':
          'security=reality&sni=front.example&pbk=$_publicKey&sid=zz',
      'REALITY invalid spider':
          'security=reality&sni=front.example&pbk=$_publicKey&spx=bad',
      'REALITY unsupported WS':
          'type=ws&security=reality&sni=front.example&pbk=$_publicKey',
      'ignored REALITY ALPN':
          'security=reality&sni=front.example&pbk=$_publicKey&alpn=h2',
      'inactive spider': 'security=tls&spx=%2F',
      'flow without TLS': 'security=none&flow=xtls-rprx-vision',
      'flow over WS': 'security=tls&type=ws&flow=xtls-rprx-vision',
      'empty ALPN item': 'security=tls&alpn=h2%2C',
      'wrong transport': 'type=hysteria&security=tls',
    };
    for (final entry in badQueries.entries) {
      test(entry.key, () => _rejected(_vless(query: entry.value)));
    }
    for (final text in [
      'trojan://password@$_server:443?flow=xtls-rprx-vision',
      'trojan://password@$_server:443?encryption=none',
      'hy2://password@$_server?security=none',
      'hy2://password@$_server?type=tcp',
      'hy2://password@$_server?obfs=salamander',
      'ss://aes-128-gcm:password@$_server:8388?plugin=anything',
      'ss://unsupported:private-password@$_server:8388',
      'vless://$_uuid@$_server:0',
      'vless://$_uuid@$_server:65536',
      'vless://$_uuid@$_server:443/unhandled',
      'trojan://@$_server:443',
      'trojan://private-password%00@$_server:443',
      'vless://$_uuid@bad_host.example:443',
    ]) {
      test('rejects invalid profile ${text.hashCode}', () => _rejected(text));
    }
    for (final change in <String, Object?>{
      'aid': 1,
      'scy': 'none',
      'net': 'kcp',
      'v': '1',
      'port': [],
      'tls': true,
    }.entries) {
      test('VMess rejects invalid ${change.key}', () {
        _rejected(
          'vmess://${_encodedJson(_vmessFields()..[change.key] = change.value)}',
        );
      });
    }
  });

  group('Trusted Xray JSON projection', () {
    test(
      'local provider configuration cannot cross into normalized profile',
      () {
        final r = const SubscriptionParser().parse(
          jsonEncode({
            'outbounds': [_outbound()],
            'inbounds': [
              {'listen': '0.0.0.0', 'port': 9999},
            ],
            'routing': {
              'rules': [
                {'outboundTag': 'direct'},
              ],
            },
            'dns': {
              'servers': ['attacker.example'],
            },
            'api': {'tag': 'remote-control'},
          }),
        );
        expect(r.profiles, hasLength(1));
        expect(r.issues.single.code, ImportIssueCode.ignoredLocalConfiguration);
        final encoded = jsonEncode(r.profiles.single.toNativeJson());
        expect(encoded, isNot(contains('inbounds')));
        expect(encoded, isNot(contains('routing')));
        expect(encoded, isNot(contains('attacker')));
      },
    );

    for (final protocol in ['vless', 'vmess']) {
      test('$protocol JSON matches URI schema', () {
        final result = _jsonImport(_outbound(protocol: protocol));
        expect(result.issues, isEmpty);
        expect(result.profiles.single.protocol.name, protocol);
        expect(result.profiles.single.uuid, _uuid);
      });
    }

    for (final protocol in ['trojan', 'shadowsocks']) {
      test('$protocol JSON projects a single server', () {
        final r = _jsonImport({
          'protocol': protocol,
          'settings': {
            'servers': [
              {
                'address': _server,
                'port': 443,
                'password': 'password',
                if (protocol == 'shadowsocks') 'method': 'aes-128-gcm',
              },
            ],
          },
          'streamSettings': {'network': 'tcp', 'security': 'tls'},
        });
        expect(r.issues, isEmpty);
        expect(r.profiles.single.password, 'password');
      });
    }

    test('Hysteria2 Xray JSON uses version 2 and explicit TLS', () {
      final r = _jsonImport({
        'protocol': 'hysteria',
        'settings': {'version': 2, 'address': _server, 'port': 443},
        'streamSettings': {
          'network': 'hysteria',
          'security': 'tls',
          'hysteriaSettings': {'version': 2, 'auth': 'password'},
        },
      });
      expect(r.issues, isEmpty);
      expect(r.profiles.single.protocol, ProxyProtocol.hysteria2);
      expect(r.profiles.single.password, 'password');
    });

    test('WS Host header is preserved and unrelated headers are rejected', () {
      final outbound = _outbound();
      outbound['streamSettings'] = {
        'network': 'ws',
        'security': 'tls',
        'wsSettings': {
          'path': '/ws',
          'headers': {'Host': 'front.example'},
        },
      };
      expect(
        _jsonImport(outbound).profiles.single.transport.host,
        'front.example',
      );
      outbound['streamSettings'] = {
        'network': 'ws',
        'security': 'tls',
        'wsSettings': {
          'headers': {'Authorization': 'private-password'},
        },
      };
      expect(_jsonImport(outbound).profiles, isEmpty);
    });

    final badStreams = <Object?>[
      [],
      1,
      null,
      {
        'network': 'tcp',
        'security': 'none',
        'tlsSettings': {'allowInsecure': true},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'realitySettings': {'publicKey': _publicKey},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'wsSettings': {'path': '/ignored'},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'allowInsecure': true},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'allowInsecure': 'false'},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {
          'alpn': [1],
        },
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'alpn': null},
      },
      {
        'network': 'tcp',
        'security': 'tls',
        'tlsSettings': {'publicKey': _publicKey},
      },
      {
        'network': 'grpc',
        'grpcSettings': {'path': '/ignored'},
      },
      {
        'network': 'xhttp',
        'xhttpSettings': {
          'headers': {'Host': 'ignored.example'},
        },
      },
      {
        'network': 'ws',
        'wsSettings': {
          'host': 'one.example',
          'headers': {'Host': 'two.example'},
        },
      },
      {
        'network': 'tcp',
        'hysteriaSettings': {'auth': 'private-password'},
      },
      {
        'network': 'tcp',
        'security': 'reality',
        'realitySettings': {
          'serverName': 'front.example',
          'publicKey': _publicKey,
          'show': true,
        },
      },
    ];
    for (var i = 0; i < badStreams.length; i++) {
      test('rejects invalid or ignored stream semantics $i', () {
        final r = _jsonImport(_outbound()..['streamSettings'] = badStreams[i]);
        expect(r.profiles, isEmpty);
        expect(r.issues, isNotEmpty);
      });
    }

    test('invalid outbound types cannot crash or prevent valid neighbors', () {
      final invalid = <Object?>[
        null,
        1,
        true,
        [],
        'password',
        {},
        {'protocol': <Object?>[]},
        {'protocol': 'vless', 'settings': 1},
      ];
      final r = const SubscriptionParser().parse(
        jsonEncode({
          'outbounds': [...invalid, _outbound()],
        }),
      );
      expect(r.profiles, hasLength(1));
      expect(r.issues, hasLength(invalid.length));
      expect(
        r.issues.map((i) => i.index),
        List.generate(invalid.length, (i) => i + 1),
      );
    });

    test(
      'unknown outbound fields reject record instead of granting local authority',
      () {
        final r = _jsonImport(
          _outbound()..['proxySettings'] = {'tag': 'direct'},
        );
        expect(r.profiles, isEmpty);
        expect(r.issues.single.code, ImportIssueCode.unsupportedFeature);
      },
    );

    test('JSON profile count has the same bound as URI subscriptions', () {
      final r = const SubscriptionParser(maxProfiles: 1).parse(
        jsonEncode({
          'outbounds': [_outbound(), _outbound()],
        }),
      );
      expect(r.issues.single.code, ImportIssueCode.tooManyProfiles);
    });

    test('duplicate JSON keys including escaped forms are rejected', () {
      _rejected('{"outbounds":[],"outbounds":[]}');
      _rejected('{"outbounds":[],"outbound\\u0073":[]}');
      _rejected(
        'vmess://${base64.encode(utf8.encode('{"id":"$_uuid","id":"other"}'))}',
      );
    });

    test('deeply nested provider JSON is bounded before decoding', () {
      _rejected('{"outbounds":[],"unused":${'[' * 65}0${']' * 65}}');
    });

    test('malformed JSON never leaks contents in diagnostics', () {
      _rejected('{"outbounds": ["private-password"');
      _rejected('{"outbounds":[]}{"secret":"private-password"}');
      _rejected('[1,2,3]');
    });
  });
}
