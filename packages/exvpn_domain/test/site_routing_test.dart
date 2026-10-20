// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

final _rejected = throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'safe error code',
    'site_routing_rejected',
  ),
);

Map<String, Object?> _policyJson({
  Object? mode = 'exclude',
  Object? rules = const ['example.invalid'],
}) => {'mode': mode, 'rules': rules};

Map<String, Object?> _presetJson({
  Object? id = 'saved-one',
  Object? name = 'Мой список',
  Object? policy,
}) => {'id': id, 'name': name, 'policy': policy ?? _policyJson()};

Map<String, Object?> _stateJson() => {
  'schema': 1,
  'policy': _policyJson(),
  'savedPresets': <Object?>[],
  'selectedPreset': 'russia-basic',
};

List<String> _rules(int count, {int start = 0}) => [
  for (var i = start; i < start + count; i++) 'r$i.example.invalid',
];

SiteRoutingPolicy _policy(int count, {int start = 0}) => SiteRoutingPolicy(
  mode: SiteRoutingMode.include,
  rules: _rules(count, start: start),
);

SiteRoutingPreset _preset(String id, SiteRoutingPolicy policy) =>
    SiteRoutingPreset(id: id, name: 'Мой список', policy: policy);

void main() {
  group('site rule normalization', () {
    test('matches the native canonical domain and IP vectors', () {
      const vectors = <String, String>{
        'EXAMPLE.COM.': 'example.com',
        'XN--E1AFMKFD.XN--P1AI': 'xn--e1afmkfd.xn--p1ai',
        '192.0.2.129/24': '192.0.2.0/24',
        '2001:0DB8:0000:0000:0000:0000:0000:0001': '2001:db8::1',
        '2001:db8:abcd::1234/48': '2001:db8:abcd::/48',
        '::ffff:192.0.2.1': '192.0.2.1',
        '::ffff:c000:201': '192.0.2.1',
        '::ffff:192.0.2.129/120': '192.0.2.0/24',
        '::ffff:192.0.2.129/96': '0.0.0.0/0',
        '::ffff:192.0.2.129/80': '::/80',
        '2001:db8::1/0': '::/0',
      };
      for (final entry in vectors.entries) {
        final actual = normalizeSiteRule(entry.key, allowUrl: false);
        expect(actual, entry.value, reason: entry.key);
        expect(normalizeSiteRule(actual, allowUrl: false), actual);
        expect(
          SiteRoutingPolicy(
            mode: SiteRoutingMode.exclude,
            rules: [actual],
          ).rules,
          [entry.value],
        );
      }
    });

    test('URL and wildcard convenience ends before native serialization', () {
      expect(
        normalizeSiteRule(' https://EXAMPLE.invalid:8443/path?q=1#part '),
        'example.invalid',
      );
      expect(normalizeSiteRule('*.Example.invalid'), 'example.invalid');
      expect(
        normalizeSiteRule('https://[2001:db8::1]:443/path'),
        '2001:db8::1',
      );
      for (final value in [
        'https://example.invalid/path',
        '*.example.invalid',
      ]) {
        expect(() => normalizeSiteRule(value, allowUrl: false), _rejected);
      }
    });

    test('rejects config syntax, ambiguous IPs, Unicode and credentials', () {
      for (final value in [
        '',
        'localhost',
        'geosite:ru',
        'regexp:.*',
        'example.invalid:443',
        'example.invalid/path',
        'example.invalid?query',
        'user@example.invalid',
        'ftp://example.invalid/path',
        'https://user:synthetic-secret@example.invalid/path',
        'a..invalid',
        '-a.invalid',
        'a-.invalid',
        'a_b.invalid',
        'a.123',
        '127.1',
        '192.0.2.001',
        '999.0.0.1',
        '192.0.2.1/33',
        '192.0.2.1/-1',
        '192.0.2.1/024',
        '2001:db8::1/129',
        '2001:db8:::1',
        'fe80::1%eth0',
        'пример.рф',
        'K.example',
        'exa\u0000mple.invalid',
        '${'a' * 64}.invalid',
        '${'a' * 63}.${'b' * 63}.${'c' * 63}.${'d' * 62}',
      ]) {
        expect(() => normalizeSiteRule(value), _rejected, reason: value);
      }
    });

    test('native policy accepts only canonical unique rules', () {
      for (final value in [
        'EXAMPLE.invalid',
        'example.invalid.',
        ' example.invalid',
        '192.0.2.129/24',
        '2001:0db8::1',
        '::ffff:192.0.2.1',
        '[2001:db8::1]',
        'https://example.invalid/',
        '*.example.invalid',
      ]) {
        expect(
          () =>
              SiteRoutingPolicy(mode: SiteRoutingMode.exclude, rules: [value]),
          _rejected,
          reason: value,
        );
      }
      expect(
        () => SiteRoutingPolicy(
          mode: SiteRoutingMode.exclude,
          rules: ['example.invalid', 'example.invalid'],
        ),
        _rejected,
      );
    });
  });

  group('local site state', () {
    test('disabled default has explicit lists and roundtrips native DTO', () {
      final state = SiteRoutingState.disabled();
      expect(state.policy.mode, SiteRoutingMode.disabled);
      expect(state.policy.active, isFalse);
      expect(state.policy.rules, isEmpty);
      expect(state.savedPresets, isEmpty);
      expect(state.selectedPreset, 'russia-basic');
      expect(state.toJson(), {
        'schema': 1,
        'policy': {'mode': 'disabled', 'rules': <String>[]},
        'savedPresets': <Object?>[],
        'selectedPreset': 'russia-basic',
      });
      final rich = SiteRoutingState(
        policy: SiteRoutingPolicy(
          mode: SiteRoutingMode.include,
          rules: ['example.invalid', '192.0.2.0/24', '2001:db8::/32'],
        ),
        savedPresets: [_preset('saved-one', _policy(2))],
        selectedPreset: 'saved-one',
      );
      expect(
        SiteRoutingState.fromJson(
          jsonDecode(jsonEncode(rich.toJson())),
        ).toJson(),
        rich.toJson(),
      );
    });

    test(
      'requires exact shapes, types and supported schema at every level',
      () {
        final invalid = <Object?>[
          null,
          <Object?>[],
          'synthetic state',
          <String, Object?>{},
          {..._stateJson()}..remove('policy'),
          {..._stateJson()}..remove('savedPresets'),
          {..._stateJson()}..remove('selectedPreset'),
          {..._stateJson(), 'outbounds': <Object?>[]},
          {..._stateJson(), 'schema': 0},
          {..._stateJson(), 'schema': 2},
          {..._stateJson(), 'schema': 1.0},
          {..._stateJson(), 'schema': '1'},
          {..._stateJson(), 'schema': true},
          {..._stateJson(), 'policy': null},
          {..._stateJson(), 'policy': <Object?>[]},
          {
            ..._stateJson(),
            'policy': {'mode': 'disabled'},
          },
          {
            ..._stateJson(),
            'policy': {'rules': <String>[]},
          },
          {
            ..._stateJson(),
            'policy': {..._policyJson(), 'outboundTag': 'direct'},
          },
          {..._stateJson(), 'policy': _policyJson(mode: 'unknown')},
          {..._stateJson(), 'policy': _policyJson(mode: null)},
          {..._stateJson(), 'policy': _policyJson(mode: 1)},
          {..._stateJson(), 'policy': _policyJson(rules: null)},
          {..._stateJson(), 'policy': _policyJson(rules: 'example.invalid')},
          {
            ..._stateJson(),
            'policy': _policyJson(rules: [1]),
          },
          {
            ..._stateJson(),
            'policy': _policyJson(rules: [null]),
          },
          {
            ..._stateJson(),
            'policy': _policyJson(rules: ['EXAMPLE.invalid']),
          },
          {..._stateJson(), 'savedPresets': null},
          {..._stateJson(), 'savedPresets': <String, Object?>{}},
          {
            ..._stateJson(),
            'savedPresets': [null],
          },
          {
            ..._stateJson(),
            'savedPresets': [_presetJson()..remove('name')],
          },
          {
            ..._stateJson(),
            'savedPresets': [
              {..._presetJson(), 'enabled': true},
            ],
          },
          {
            ..._stateJson(),
            'savedPresets': [_presetJson(id: 1)],
          },
          {
            ..._stateJson(),
            'savedPresets': [_presetJson(name: false)],
          },
          {..._stateJson(), 'selectedPreset': null},
          {..._stateJson(), 'selectedPreset': 1},
          {..._stateJson(), 1: 'unexpected key'},
        ];
        for (var i = 0; i < invalid.length; i++) {
          expect(
            () => SiteRoutingState.fromJson(invalid[i]),
            _rejected,
            reason: 'invalid DTO case $i',
          );
        }
      },
    );

    test(
      'safe preset identities are bounded in runes and reject hidden text',
      () {
        final policy = _policy(0);
        for (final id in [
          '',
          '-first',
          'UPPER',
          '../escape',
          'a/b',
          'a' * 65,
        ]) {
          expect(() => _preset(id, policy), _rejected, reason: id);
          expect(
            () => SiteRoutingState(policy: policy, selectedPreset: id),
            id.isEmpty ? returnsNormally : _rejected,
          );
        }
        for (final name in [
          '',
          ' ',
          ' leading',
          'trailing ',
          'line\nfeed',
          'hidden\u200btext',
          'bidi\u202etext',
          'hidden\u0600text',
          'tag\u{e0001}text',
          '😀' * 81,
        ]) {
          expect(
            () => SiteRoutingPreset(id: 'saved', name: name, policy: policy),
            _rejected,
            reason: 'unsafe preset name',
          );
        }
        expect(
          SiteRoutingPreset(
            id: 'safe.1_-',
            name: '😀' * 80,
            policy: policy,
          ).name,
          '😀' * 80,
        );
        expect(
          SiteRoutingState(
            policy: policy,
            selectedPreset: 'future-builtin',
          ).selectedPreset,
          'future-builtin',
        );
      },
    );

    test(
      'include with no rules remains active and disabling retains rules',
      () {
        for (final mode in SiteRoutingMode.values) {
          for (final rules in [
            <String>[],
            ['example.invalid'],
          ]) {
            final policy = SiteRoutingPolicy(mode: mode, rules: rules);
            expect(
              policy.active,
              mode == SiteRoutingMode.include ||
                  (mode == SiteRoutingMode.exclude && rules.isNotEmpty),
            );
            expect(policy.rules, rules);
          }
        }
      },
    );

    test('policy limits reject the extra rule before persistence', () {
      expect(_policy(1024).rules, hasLength(1024));
      expect(() => _policy(1025), _rejected);
      expect(
        () => SiteRoutingPolicy.fromJson(_policyJson(rules: _rules(1025))),
        _rejected,
      );
    });

    test('preset library is bounded and IDs are unique', () {
      final policy = _policy(0);
      final eight = [for (var i = 0; i < 8; i++) _preset('saved-$i', policy)];
      expect(
        SiteRoutingState(policy: policy, savedPresets: eight).savedPresets,
        hasLength(8),
      );
      expect(
        () => SiteRoutingState(
          policy: policy,
          savedPresets: [...eight, _preset('saved-8', policy)],
        ),
        _rejected,
      );
      expect(
        () => SiteRoutingState(
          policy: policy,
          savedPresets: [_preset('same', policy), _preset('same', policy)],
        ),
        _rejected,
      );
    });

    test('2048 total rules is accepted but a further saved rule is not', () {
      final policy = _policy(1024);
      final saved = _preset('saved', _policy(1024, start: 1024));
      expect(
        SiteRoutingState(policy: policy, savedPresets: [saved]).savedPresets,
        hasLength(1),
      );
      expect(
        () => SiteRoutingState(
          policy: policy,
          savedPresets: [saved, _preset('extra', _policy(1, start: 2048))],
        ),
        _rejected,
      );
    });

    test('encoded size bound also applies below rule count limits', () {
      final longest = [
        for (var i = 0; i < 2048; i++)
          'r${i.toString().padLeft(4, '0')}${'a' * 58}.${'b' * 63}.${'c' * 63}.${'d' * 61}',
      ];
      expect(longest.first.length, 253);
      final json = {
        ..._stateJson(),
        'policy': _policyJson(rules: longest.take(1024).toList()),
        'savedPresets': [
          _presetJson(policy: _policyJson(rules: longest.skip(1024).toList())),
        ],
      };
      expect(utf8.encode(jsonEncode(json)).length, greaterThan(512 * 1024));
      expect(() => SiteRoutingState.fromJson(json), _rejected);
    });

    test('size accounting includes native JSON escaping in preset names', () {
      final longest = [
        for (var i = 0; i < 2040; i++)
          'r${i.toString().padLeft(4, '0')}${'a' * 58}.${'b' * 63}.${'c' * 63}.${'d' * 61}',
      ];
      final json = {
        ..._stateJson(),
        'policy': _policyJson(rules: longest.take(1024).toList()),
        'savedPresets': [
          for (var i = 0; i < 8; i++)
            _presetJson(
              id: 'saved-$i',
              name: '${'<>&' * 26}<>',
              policy: _policyJson(
                rules: i == 0 ? longest.skip(1024).toList() : <String>[],
              ),
            ),
        ],
      };
      final encoded = jsonEncode(json);
      final nativeEncoded = encoded
          .replaceAll('<', r'\u003c')
          .replaceAll('>', r'\u003e')
          .replaceAll('&', r'\u0026');
      expect(utf8.encode(encoded).length, lessThan(512 * 1024));
      expect(utf8.encode(nativeEncoded).length, greaterThan(512 * 1024));
      expect(() => SiteRoutingState.fromJson(json), _rejected);

      final withoutEscaping = jsonDecode(encoded) as Map<String, Object?>;
      for (final preset in withoutEscaping['savedPresets']! as List<Object?>) {
        (preset! as Map<String, Object?>)['name'] = 'a' * 80;
      }
      expect(
        SiteRoutingState.fromJson(withoutEscaping).savedPresets,
        hasLength(8),
      );
    });

    test('snapshots rule and preset collections without mutable aliases', () {
      final rules = ['example.invalid'];
      final policy = SiteRoutingPolicy(
        mode: SiteRoutingMode.exclude,
        rules: rules,
      );
      final saved = [_preset('saved', policy)];
      final state = SiteRoutingState(policy: policy, savedPresets: saved);
      rules[0] = 'changed.invalid';
      saved.clear();
      expect(state.policy.rules, ['example.invalid']);
      expect(state.savedPresets.single.policy.rules, ['example.invalid']);
      expect(
        () => state.policy.rules.add('changed.invalid'),
        throwsUnsupportedError,
      );
      expect(() => state.savedPresets.clear(), throwsUnsupportedError);
      expect(
        () => state.savedPresets.single.policy.rules.clear(),
        throwsUnsupportedError,
      );

      final sourceRules = ['parsed.invalid'];
      final sourcePresets = [_presetJson()];
      final parsed = SiteRoutingState.fromJson({
        ..._stateJson(),
        'policy': _policyJson(rules: sourceRules),
        'savedPresets': sourcePresets,
      });
      sourceRules.clear();
      sourcePresets.clear();
      expect(parsed.policy.rules, ['parsed.invalid']);
      expect(parsed.savedPresets, hasLength(1));
      final encoded = parsed.toJson();
      encoded.clear();
      expect(parsed.policy.rules, ['parsed.invalid']);
      expect(parsed.savedPresets.single.id, 'saved-one');
    });
  });
}
