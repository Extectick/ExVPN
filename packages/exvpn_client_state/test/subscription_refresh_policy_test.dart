import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const _old =
    'vless://00000000-0000-4000-8000-000000000001@old.invalid:443?security=tls#Old';
const _new =
    'vless://00000000-0000-4000-8000-000000000002@new.invalid:443?security=tls#New';
const _unknown = 'unknown://synthetic-credential@unsupported.invalid';
const _unsupported =
    'vless://00000000-0000-4000-8000-000000000003@unsupported.invalid:443?type=quic';
const _malformed = 'vless://not-a-uuid@invalid.invalid:443?security=tls';

void main() {
  for (final (label, rejected, codes) in [
    ('protocol', _unknown, [ImportIssueCode.unsupportedProtocol]),
    ('feature', _unsupported, [ImportIssueCode.unsupportedFeature]),
    (
      'protocol and feature',
      '$_unknown\n$_unsupported',
      [ImportIssueCode.unsupportedProtocol, ImportIssueCode.unsupportedFeature],
    ),
  ]) {
    test('refresh applies supported records while skipping $label', () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app
          .addSubscription(
            raw: _old,
            providerName: 'Old provider',
            sourceUrl: 'https://source.invalid/old',
          )
          .groupId;
      final beforeRevision = app.groups.single.contentRevision;
      app.toggleGroup(id);

      final result = app.updateSubscription(
        groupId: id,
        raw: '$_new\n$rejected',
        providerName: 'New provider',
        sourceUrl: 'https://source.invalid/new',
      );

      expect(result.applied, isTrue);
      expect(result.issues.map((issue) => issue.code), codes);
      expect(app.groups.single.servers.map((entry) => entry.name), ['New']);
      expect(app.groups.single.name, 'New provider');
      expect(app.groups.single.sourceUrl, 'https://source.invalid/new');
      expect(app.groups.single.contentRevision, beforeRevision + 1);
      expect(app.groups.single.expanded, isFalse);
      expect(app.pendingUpdate(id), isNull);
      expect(app.selectedServer!.name, 'New');
      expect(result.issues.toString(), isNot(contains('synthetic-credential')));

      final restored = AppController.fromSnapshot(
        Map<String, dynamic>.from(app.exportSnapshot()),
      );
      addTearDown(restored.dispose);
      expect(restored.selectedServer!.name, 'New');
      expect(restored.groups.single.name, 'New provider');
    });
  }

  test('all skippable JSON issues never import local or security policy', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app.addSubscription(name: 'My name', raw: _old).groupId;
    final valid = {
      'tag': 'New',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': 'new.invalid',
            'port': 443,
            'users': [
              {'id': '00000000-0000-4000-8000-000000000002'},
            ],
          },
        ],
      },
      'streamSettings': {'security': 'tls'},
    };
    final result = app.updateSubscription(
      groupId: id,
      providerName: 'Provider title',
      raw: jsonEncode({
        'outbounds': [
          valid,
          {'protocol': 'future-protocol'},
          {...valid, 'unsupportedField': true},
        ],
        'inbounds': [
          {'listen': '0.0.0.0', 'port': 9999},
        ],
        'routing': {'domainStrategy': 'UseIP'},
        'api': {'listen': '0.0.0.0:10085'},
        'updates': {'trustedKey': 'synthetic-injected-key'},
      }),
    );
    expect(result.applied, isTrue);
    expect(result.issues.map((issue) => issue.code), [
      ImportIssueCode.ignoredLocalConfiguration,
      ImportIssueCode.unsupportedProtocol,
      ImportIssueCode.unsupportedFeature,
    ]);
    expect(app.groups.single.name, 'My name');
    expect(app.groups.single.providerName, 'Provider title');
    expect(app.groups.single.servers, hasLength(1));
    final persisted = jsonEncode(app.exportSnapshot());
    for (final forbidden in [
      'inbounds',
      'routing',
      '0.0.0.0',
      '10085',
      'trustedKey',
      'synthetic-injected-key',
      'unsupportedField',
    ]) {
      expect(persisted, isNot(contains(forbidden)));
    }
  });

  test('auto-applied partial preserves a surviving selected profile', () {
    final app = AppController();
    addTearDown(app.dispose);
    final id = app.addSubscription(raw: '$_old\n$_new').groupId;
    final selected = app.groups.single.servers.last.id;
    app.selectServer(groupId: id, serverId: selected);
    final result = app.updateSubscription(
      groupId: id,
      raw: '$_new\n$_old\n$_unknown',
    );
    expect(result.applied, isTrue);
    expect(app.selectedServerId, selected);
  });

  for (final initiallyEmpty in [false, true]) {
    test('invalid record cannot auto-apply even with skippable issues '
        '(initially empty: $initiallyEmpty)', () {
      final app = AppController();
      addTearDown(app.dispose);
      final id = app
          .addSubscription(
            raw: initiallyEmpty ? '' : _old,
            providerName: 'Retained title',
            sourceUrl: 'https://source.invalid/old',
          )
          .groupId;
      final before = app.groups.single;
      final result = app.updateSubscription(
        groupId: id,
        raw: '$_new\n$_unknown\n$_malformed',
        providerName: 'Unaccepted title',
        sourceUrl: 'https://source.invalid/new',
      );
      expect(result.applied, isFalse);
      expect(result.issues.map((issue) => issue.code), [
        ImportIssueCode.unsupportedProtocol,
        ImportIssueCode.invalidProfile,
      ]);
      expect(app.groups.single.servers, before.servers);
      expect(app.groups.single.name, before.name);
      expect(app.groups.single.providerName, before.providerName);
      expect(app.groups.single.sourceUrl, before.sourceUrl);
      expect(app.groups.single.updatedAt, before.updatedAt);
      expect(app.groups.single.contentRevision, before.contentRevision);
    });
  }

  for (final (label, raw, parser, code) in [
    ('empty', '', const SubscriptionParser(), ImportIssueCode.empty),
    (
      'unsupported only',
      _unknown,
      const SubscriptionParser(),
      ImportIssueCode.unsupportedProtocol,
    ),
    (
      'malformed JSON',
      '{"outbounds":[',
      const SubscriptionParser(),
      ImportIssueCode.unsupportedFormat,
    ),
    (
      'unsupported format',
      '{"servers":[]}',
      const SubscriptionParser(),
      ImportIssueCode.unsupportedFormat,
    ),
    (
      'too large',
      '$_new\n#${List.filled(64, 'x').join()}',
      const SubscriptionParser(maxBytes: 100),
      ImportIssueCode.tooLarge,
    ),
    (
      'too many',
      '$_new\n$_unknown',
      const SubscriptionParser(maxProfiles: 1),
      ImportIssueCode.tooManyProfiles,
    ),
  ]) {
    test('$label refresh retains working content and metadata', () {
      final app = AppController(parser: parser);
      addTearDown(app.dispose);
      final id = app
          .addSubscription(raw: _old, providerName: 'Retained title')
          .groupId;
      final before = app.groups.single;
      expect(before.servers, hasLength(1));
      final result = app.updateSubscription(
        groupId: id,
        raw: raw,
        providerName: 'Unaccepted title',
      );
      expect(result.applied, isFalse);
      expect(result.issues.single.code, code);
      expect(app.groups.single.servers, before.servers);
      expect(app.groups.single.name, before.name);
      expect(app.groups.single.updatedAt, before.updatedAt);
      expect(app.groups.single.contentRevision, before.contentRevision);
      expect(app.pendingUpdate(id), isNull);
    });
  }
}
