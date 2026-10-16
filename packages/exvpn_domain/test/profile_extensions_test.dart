import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const _uuid = '123e4567-e89b-12d3-a456-426614174000';
const _password = 'synthetic-sudoku-password';
String _key(int length, [int byte = 1]) =>
    base64Url.encode(List<int>.filled(length, byte)).replaceAll('=', '');
String _encryption({
  String? key,
  String mode = 'native',
  String rtt = '1rtt',
}) => 'mlkem768x25519plus.$mode.$rtt.${key ?? _key(32)}';
Map<String, Object?> _mask([Map<String, Object?>? settings]) => {
  'tcp': [
    {
      'type': 'sudoku',
      'settings': settings ?? {'password': _password},
    },
  ],
};
String _link({
  String? encryption,
  Object? mask,
  String security = 'none',
  String type = 'tcp',
  String? flow,
}) => Uri(
  scheme: 'vless',
  userInfo: _uuid,
  host: 'node.example',
  port: 443,
  queryParameters: {
    'security': security,
    'type': type,
    'encryption': ?encryption,
    if (mask != null) 'fm': mask is String ? mask : jsonEncode(mask),
    'flow': ?flow,
  },
  fragment: 'Synthetic node',
).toString();

Map<String, Object?> _outbound({Object? encryption, Object? mask}) => {
  'tag': 'Synthetic node',
  'protocol': 'vless',
  'settings': {
    'vnext': [
      {
        'address': 'node.example',
        'port': 443,
        'users': [
          {'id': _uuid, 'encryption': encryption ?? _encryption()},
        ],
      },
    ],
  },
  'streamSettings': {
    'network': 'tcp',
    'security': 'none',
    'finalmask': mask ?? _mask(),
  },
};
String _json(Object outbound) => jsonEncode({
  'outbounds': [outbound],
});
ConnectionProfile _single(String input) {
  final result = const SubscriptionParser().parse(input);
  expect(result.issues, isEmpty);
  expect(result.profiles, hasLength(1));
  return result.profiles.single;
}

void _rejected(String input, {ImportIssueCode? code}) {
  final result = const SubscriptionParser().parse(input);
  expect(result.profiles, isEmpty);
  expect(result.issues, isNotEmpty);
  if (code != null) expect(result.issues.single.code, code);
  final diagnostic = result.issues.toString();
  for (final secret in [_uuid, _password, 'node.example', _key(32)]) {
    expect(diagnostic, isNot(contains(secret)));
  }
}

void main() {
  group('VLESS authenticated encryption grammar', () {
    for (final mode in ['native', 'xorpub', 'random']) {
      for (final rtt in ['0rtt', '1rtt']) {
        test('$mode/$rtt keeps supported peer keys', () {
          final value = _encryption(
            key: '${_key(32)}.${_key(1184, 2)}',
            mode: mode,
            rtt: rtt,
          );
          expect(VlessEncryption.parse(value).value, value);
        });
      }
    }
    test('accepts bounded padding before up to four keys', () {
      final value =
          'mlkem768x25519plus.native.1rtt.'
          '100-35-65500.0-0-1000.100-0-53.'
          '${_key(32)}.${_key(1184)}.${_key(32, 2)}.${_key(32, 3)}';
      expect(VlessEncryption.parse(value).value, value);
    });
    test('checks MLKEM coefficient bounds but not the arbitrary seed', () {
      final bytes = List<int>.filled(1184, 0);
      bytes.fillRange(1152, 1184, 255);
      bytes.setRange(0, 3, [0, 13, 208]); // Both coefficients are 3328.
      String value() =>
          _encryption(key: base64Url.encode(bytes).replaceAll('=', ''));
      expect(VlessEncryption.parse(value()).value, value());
      bytes[0] = 1; // First coefficient is 3329.
      _rejected(
        _link(encryption: value()),
        code: ImportIssueCode.invalidProfile,
      );
      bytes.setRange(0, 3, [0, 29, 208]); // Second coefficient is 3329.
      _rejected(
        _link(encryption: value()),
        code: ImportIssueCode.invalidProfile,
      );
      bytes.setRange(0, 3, [0, 0, 0]);
      bytes.setRange(1149, 1152, [255, 255, 255]); // Last polynomial pair.
      _rejected(
        _link(encryption: value()),
        code: ImportIssueCode.invalidProfile,
      );
    });
    final invalid = <String, String>{
      'missing peer key': 'mlkem768x25519plus.native.1rtt',
      'unknown algorithm': _encryption().replaceFirst('mlkem768', 'other'),
      'unknown mode': _encryption(mode: 'unchecked'),
      'unknown RTT': _encryption(rtt: '2rtt'),
      'zero key': _encryption(key: _key(32, 0)),
      'short key': _encryption(key: _key(31)),
      'long X25519 key': _encryption(key: _key(33)),
      'short MLKEM key': _encryption(key: _key(1183)),
      'long MLKEM key': _encryption(key: _key(1185)),
      'padded base64': _encryption(key: '${_key(32)}='),
      'noncanonical base64 tail': _encryption(
        key: '${_key(32).substring(0, 42)}F',
      ),
      'invalid base64 length': _encryption(key: 'A' * 21),
      'too many keys': _encryption(key: List.filled(5, _key(32)).join('.')),
      'padding after key': '${_encryption()}.100-35-100',
      'padding leading zero': _encryption(key: '100-035-100.${_key(32)}'),
      'first padding probability': _encryption(key: '99-35-100.${_key(32)}'),
      'first padding short': _encryption(key: '100-34-100.${_key(32)}'),
      'padding probability range': _encryption(key: '101-35-100.${_key(32)}'),
      'reversed padding': _encryption(key: '100-100-35.${_key(32)}'),
      'payload padding range': _encryption(key: '100-35-65554.${_key(32)}'),
      'delay padding range': _encryption(
        key: '100-35-100.1-0-1001.${_key(32)}',
      ),
      'aggregate padding range': _encryption(
        key: '100-35-65553.1-0-1.1-0-1.${_key(32)}',
      ),
      'too many padding entries': _encryption(
        key: '100-35-35.${List.filled(15, '0-0-0').join('.')}.${_key(32)}',
      ),
      'oversized encryption': 'A' * 8193,
    };
    for (final entry in invalid.entries) {
      test('rejects ${entry.key} without exposing source', () {
        expect(
          () => VlessEncryption.parse(entry.value),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'safe diagnostic',
              'FormatException: Invalid profile extension',
            ),
          ),
        );
        _rejected(_link(encryption: entry.value));
      });
    }
    test('credential objects redact their printable representation', () {
      final profile = _single(_link(encryption: _encryption(), mask: _mask()));
      expect(profile.toString(), 'ConnectionProfile(<redacted>)');
      expect(profile.encryption.toString(), 'VlessEncryption(<redacted>)');
      expect(
        profile.transport.tcpSudoku.toString(),
        'SudokuOptions(<redacted>)',
      );
    });
  });

  group('typed TCP Sudoku import', () {
    test('URI and Xray JSON preserve exactly the same normalized profile', () {
      final uri = _single(_link(encryption: _encryption(), mask: _mask()));
      final json = _single(_json(_outbound()));
      expect(uri.toNativeJson(), json.toNativeJson());
      expect(uri.transport.tcpSudoku!.password, _password);
      expect(uri.tls.enabled, isFalse);
    });
    test('TLS authenticates Sudoku without VLESS encryption', () {
      final profile = _single(_link(mask: _mask(), security: 'tls'));
      expect(profile.tls.enabled, isTrue);
      expect(profile.encryption, isNull);
    });
    test(
      'Vision preserves encryption as authentication with outer TLS absent',
      () {
        final profile = _single(
          _link(
            encryption: _encryption(),
            mask: _mask(),
            flow: 'xtls-rprx-vision',
          ),
        );
        expect(profile.flow, 'xtls-rprx-vision');
        expect(profile.encryption, isNotNull);
        expect(profile.tls.enabled, isFalse);
      },
    );
    test(
      'unauthenticated Sudoku and Vision cannot silently bypass protection',
      () {
        _rejected(
          _link(mask: _mask()),
          code: ImportIssueCode.unsupportedFeature,
        );
        _rejected(
          _link(encryption: 'none', flow: 'xtls-rprx-vision'),
          code: ImportIssueCode.unsupportedFeature,
        );
      },
    );
    test('aliases and equivalent table whitespace have a stable identity', () {
      final first = _single(
        _link(
          encryption: _encryption(),
          mask: _mask({
            'password': _password,
            'ascii': 'entropy',
            'custom_table': ' X X P P V V V V ',
            'padding_min': 5,
            'padding_max': 20,
          }),
        ),
      );
      final second = _single(
        _link(
          encryption: _encryption(),
          mask: _mask({
            'password': _password,
            'ascii': 'prefer_entropy',
            'customTables': ['xxppvvvv', 'xxppvvvv'],
            'paddingMin': 5,
            'paddingMax': 20,
          }),
        ),
      );
      expect(first.id, second.id);
      expect(first.transport.tcpSudoku!.toJson(), {
        'password': _password,
        'customTables': ['xxppvvvv'],
        'paddingMin': 5,
        'paddingMax': 20,
      });
      expect(
        () => first.transport.tcpSudoku!.customTables.add('ppxxvvvv'),
        throwsUnsupportedError,
      );
    });
    test('ASCII preference has its own canonical mode', () {
      expect(
        SudokuOptions.fromJson({
          'password': _password,
          'ascii': ' ASCII ',
        }).ascii,
        'prefer_ascii',
      );
    });
    final invalidSettings = <String, Map<String, Object?>>{
      'missing password': {},
      'null password': {'password': null},
      'numeric password': {'password': 123},
      'control character': {'password': 'private\npassword'},
      'oversized password': {'password': 'x' * 4097},
      'UTF8 password bound': {'password': 'я' * 2049},
      'unknown field': {'password': _password, 'routing': {}},
      'numeric ASCII': {'password': _password, 'ascii': 1},
      'unknown ASCII': {'password': _password, 'ascii': 'opaque'},
      'fractional padding': {'password': _password, 'paddingMin': 1.5},
      'string padding': {'password': _password, 'paddingMax': '10'},
      'negative padding': {'password': _password, 'paddingMin': -1},
      'padding above 100': {'password': _password, 'paddingMax': 101},
      'reversed padding': {
        'password': _password,
        'paddingMin': 21,
        'paddingMax': 20,
      },
      'duplicate alias': {
        'password': _password,
        'padding_min': 0,
        'paddingMin': 0,
      },
      'both table forms': {
        'password': _password,
        'customTable': '',
        'customTables': [],
      },
      'non-list tables': {'password': _password, 'customTables': 'xxppvvvv'},
      'non-string table': {
        'password': _password,
        'customTables': [1],
      },
      'wrong table counts': {'password': _password, 'customTable': 'xxppvvv?'},
      'too many tables': {
        'password': _password,
        'customTables': List.filled(5, 'xxppvvvv'),
      },
      'ASCII with table': {
        'password': _password,
        'ascii': 'ascii',
        'customTable': 'xxppvvvv',
      },
    };
    for (final entry in invalidSettings.entries) {
      test('rejects ${entry.key} in URI and JSON', () {
        _rejected(_link(encryption: _encryption(), mask: _mask(entry.value)));
        _rejected(_json(_outbound(mask: _mask(entry.value))));
      });
    }
    final invalidMasks = <String, Object>{
      'arbitrary routing': {
        ..._mask(),
        'routing': {'domainStrategy': 'IPIfNonMatch'},
      },
      'UDP mask': {..._mask(), 'udp': <Object?>[]},
      'non-list TCP': {'tcp': <String, Object?>{}},
      'empty TCP chain': {'tcp': <Object?>[]},
      'multiple masks': {
        'tcp': [..._mask()['tcp'] as List, ..._mask()['tcp'] as List],
      },
      'unknown mask type': {
        'tcp': [
          {
            'type': 'custom',
            'settings': {'password': _password},
          },
        ],
      },
      'unknown mask entry': {
        'tcp': [
          {
            'type': 'sudoku',
            'settings': {'password': _password},
            'inbounds': <Object?>[],
          },
        ],
      },
      'invalid settings': {
        'tcp': [
          {'type': 'sudoku', 'settings': <Object?>[]},
        ],
      },
      'duplicate JSON key':
          '{"tcp":[{"type":"sudoku","settings":{"password":"$_password","password":"replacement"}}]}',
      'escaped duplicate JSON key':
          r'{"tcp":[{"type":"sudoku","settings":{"password":"one","pass\u0077ord":"two"}}]}',
    };
    for (final entry in invalidMasks.entries) {
      test(
        'rejects ${entry.key}',
        () => _rejected(_link(encryption: _encryption(), mask: entry.value)),
      );
    }
    test('rejects duplicate URI fields, even when values agree', () {
      final link = _link(encryption: _encryption(), mask: _mask());
      final duplicate = link.replaceFirst(
        '#',
        '&fm=${Uri.encodeQueryComponent(jsonEncode(_mask()))}#',
      );
      _rejected(duplicate, code: ImportIssueCode.invalidProfile);
    });
    test('rejects Sudoku on transports and protocols outside the schema', () {
      for (final type in ['ws', 'grpc', 'xhttp']) {
        _rejected(_link(encryption: _encryption(), mask: _mask(), type: type));
      }
      _rejected(
        _link(
          mask: _mask(),
          security: 'tls',
        ).replaceFirst('vless://$_uuid', 'trojan://password'),
      );
      _rejected(
        _link(
          encryption: _encryption(),
          security: 'tls',
        ).replaceFirst('vless://$_uuid', 'hy2://password'),
      );
    });
    test(
      'invalid JSON encryption types cannot become a permissive default',
      () {
        for (final value in [0, true, <String>[], <String, Object?>{}]) {
          _rejected(_json(_outbound(encryption: value)));
        }
      },
    );
    test(
      'local provider configuration stays outside the normalized profile',
      () {
        final result = const SubscriptionParser().parse(
          jsonEncode({
            'outbounds': [_outbound()],
            'routing': {
              'rules': [
                {'outboundTag': 'direct'},
              ],
            },
            'inbounds': [
              {'port': 1080},
            ],
          }),
        );
        expect(result.profiles, hasLength(1));
        expect(
          result.issues.single.code,
          ImportIssueCode.ignoredLocalConfiguration,
        );
        final encoded = jsonEncode(result.profiles.single.toNativeJson());
        expect(encoded, isNot(contains('routing')));
        expect(encoded, isNot(contains('inbounds')));
        expect(encoded, isNot(contains('outboundTag')));
      },
    );
  });

  group('profile identity compatibility', () {
    test('existing VLESS and Hy2 IDs stay byte-for-byte stable', () {
      // Captured by running the pre-extension HEAD parser, not recomputed here.
      expect(
        _single(
          'vless://$_uuid@node.example:443?security=tls&sni=front.example#Node',
        ).id,
        'b5cea5f560d158bf79e0fe5655c6e7b94d29e2137a2bbc186346214df78a8f05',
      );
      expect(
        _single(
          'hy2://synthetic-hy2-password@hy.example:443?sni=front.example#Hy2',
        ).id,
        '5f8293ef0a0939336b9d07c1a869a3c0b8011028519651a46fc67103517cf5a4',
      );
      expect(_single(_link()).id, _single(_link(encryption: 'none')).id);
    });
    test(
      'authentication, masking and padding changes cannot reuse selected ID',
      () {
        final variants = [
          _link(encryption: _encryption()),
          _link(encryption: _encryption(key: _key(32, 2))),
          _link(encryption: _encryption(mode: 'random')),
          _link(encryption: _encryption(rtt: '0rtt')),
          _link(encryption: _encryption(), mask: _mask()),
          _link(
            encryption: _encryption(),
            mask: _mask({'password': 'different-secret'}),
          ),
          _link(
            encryption: _encryption(),
            mask: _mask({'password': _password, 'paddingMax': 10}),
          ),
          _link(
            encryption: _encryption(),
            mask: _mask({'password': _password, 'customTable': 'xxppvvvv'}),
          ),
          _link(
            encryption: _encryption(),
            mask: _mask({'password': _password, 'ascii': 'ascii'}),
          ),
        ];
        expect(
          variants.map((input) => _single(input).id).toSet(),
          hasLength(variants.length),
        );
      },
    );
  });
}
