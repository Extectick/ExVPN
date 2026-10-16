import 'dart:convert';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:test/test.dart';

const _uuid = '123e4567-e89b-12d3-a456-426614174000';
const _password = 'synthetic-sudoku-password';
final _key = base64Url.encode(List<int>.filled(32, 1)).replaceAll('=', '');
final _encryption = 'mlkem768x25519plus.native.1rtt.$_key';
final _uri = Uri(
  scheme: 'vless',
  userInfo: _uuid,
  host: 'node.example',
  port: 443,
  queryParameters: {
    'encryption': _encryption,
    'security': 'none',
    'flow': 'xtls-rprx-vision',
    'fm': jsonEncode({
      'tcp': [
        {
          'type': 'sudoku',
          'settings': {
            'password': _password,
            'custom_table': 'xxppvvvv',
            'padding_min': 5,
            'padding_max': 20,
          },
        },
      ],
    }),
  },
  fragment: 'Synthetic authenticated node',
).toString();

Map<String, dynamic> _snapshot(AppController controller) =>
    jsonDecode(jsonEncode(controller.exportSnapshot())) as Map<String, dynamic>;
Map<String, dynamic> _profile(Map<String, dynamic> snapshot) =>
    snapshot['groups'][0]['profiles'][0] as Map<String, dynamic>;
AppController _import() {
  final controller = AppController()
    ..addSubscription(name: 'Synthetic group', raw: _uri);
  expect(controller.groups.single.issues, isEmpty);
  expect(controller.groups.single.servers, hasLength(1));
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test(
    'Encryption and Sudoku survive protected snapshot round trip without defaulting',
    () {
      final controller = _import();
      controller.toggleGroup(controller.groups.single.id);
      final restored = AppController.fromSnapshot(_snapshot(controller));
      addTearDown(restored.dispose);
      final profile = restored.selectedServer!.profile;
      expect(
        profile.toNativeJson(),
        controller.selectedServer!.profile.toNativeJson(),
      );
      expect(restored.selectedServerId, controller.selectedServerId);
      expect(restored.groups.single.expanded, isFalse);
      expect(profile.encryption!.value, _encryption);
      expect(profile.flow, 'xtls-rprx-vision');
      expect(profile.tls.enabled, isFalse);
      expect(profile.transport.tcpSudoku!.toJson(), {
        'password': _password,
        'customTables': ['xxppvvvv'],
        'paddingMin': 5,
        'paddingMax': 20,
      });
    },
  );

  test(
    'Hysteria2 profiles with their transport and TLS survive application restart',
    () {
      final controller = AppController()
        ..addSubscription(
          name: 'Hy2',
          raw:
              'hy2://synthetic-hy2-password@hy.example:443?sni=front.example#Hy2',
        );
      addTearDown(controller.dispose);
      expect(controller.groups.single.issues, isEmpty);
      final restored = AppController.fromSnapshot(_snapshot(controller));
      addTearDown(restored.dispose);
      expect(restored.selectedServer!.profile.transport.type, 'hysteria');
      expect(restored.selectedServer!.profile.tls.enabled, isTrue);
      expect(
        restored.selectedServer!.profile.password,
        'synthetic-hy2-password',
      );
      expect(
        restored.selectedServer!.profile.toNativeJson(),
        controller.selectedServer!.profile.toNativeJson(),
      );
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'explicit null encryption': (p) => p['encryption'] = null,
    'explicit null Sudoku': (p) => p['transport']['tcpSudoku'] = null,
    'both security extensions null': (p) {
      p.remove('flow');
      p['encryption'] = null;
      p['transport']['tcpSudoku'] = null;
    },
    'encryption wrong type': (p) => p['encryption'] = 123,
    'encryption malformed': (p) =>
        p['encryption'] = 'mlkem768x25519plus.native.1rtt.${'A' * 21}',
    'encryption on other protocol': (p) => p['protocol'] = 'vmess',
    'Sudoku on WebSocket': (p) => p['transport']['type'] = 'ws',
    'Sudoku on gRPC': (p) => p['transport']['type'] = 'grpc',
    'Sudoku without peer authentication': (p) => p.remove('encryption'),
    'arbitrary stream configuration': (p) =>
        p['transport']['sockopt'] = {'mark': 1},
    'arbitrary mask configuration': (p) =>
        p['transport']['tcpSudoku']['routing'] = <String, Object?>{},
    'provider aliases in persisted schema': (p) =>
        p['transport']['tcpSudoku']['padding_min'] = 1,
    'Sudoku wrong type': (p) => p['transport']['tcpSudoku'] = <Object?>[],
    'Sudoku missing password': (p) =>
        (p['transport']['tcpSudoku'] as Map).remove('password'),
    'Sudoku numeric password': (p) =>
        p['transport']['tcpSudoku']['password'] = 1,
    'Sudoku fractional padding': (p) =>
        p['transport']['tcpSudoku']['paddingMin'] = 1.5,
    'Sudoku padding bounds': (p) =>
        p['transport']['tcpSudoku']['paddingMax'] = 101,
    'Sudoku table type': (p) =>
        p['transport']['tcpSudoku']['customTables'] = 'xxppvvvv',
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} atomically with a safe storage error', () {
      final controller = _import();
      final snapshot = _snapshot(controller);
      entry.value(_profile(snapshot));
      expect(
        () => AppController.fromSnapshot(snapshot),
        throwsA(
          isA<SnapshotFormatException>().having(
            (error) => error.toString(),
            'safe diagnostic',
            'SnapshotFormatException(invalid_snapshot)',
          ),
        ),
      );
      expect(controller.selectedServer!.profile.encryption!.value, _encryption);
      expect(
        controller.selectedServer!.profile.transport.tcpSudoku!.password,
        _password,
      );
    });
  }

  test('an old profile snapshot without extension fields stays readable', () {
    final controller = AppController()
      ..addSubscription(
        name: 'Legacy',
        raw: 'vless://$_uuid@node.example:443?security=tls#Legacy',
      );
    addTearDown(controller.dispose);
    final snapshot = _snapshot(controller);
    expect(_profile(snapshot).containsKey('encryption'), isFalse);
    expect(
      (_profile(snapshot)['transport'] as Map).containsKey('tcpSudoku'),
      isFalse,
    );
    final restored = AppController.fromSnapshot(snapshot);
    addTearDown(restored.dispose);
    expect(restored.selectedServerId, controller.selectedServerId);
    expect(restored.selectedServer!.profile.encryption, isNull);
    expect(restored.selectedServer!.profile.transport.tcpSudoku, isNull);
  });
}
