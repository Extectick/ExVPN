import 'dart:convert';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:test/test.dart';

const uuid = '123e4567-e89b-12d3-a456-426614174000';
Map<String, dynamic> xray() => {
  'tag': 'Synthetic',
  'protocol': 'vless',
  'settings': {
    'vnext': [
      {
        'address': 'node.example',
        'port': 443,
        'users': [
          {'id': uuid, 'encryption': 'none'},
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
Map<String, dynamic> sing({String protocol = 'vless'}) => {
  'type': protocol,
  'tag': 'Synthetic',
  'server': 'node.example',
  'server_port': 443,
  if (protocol == 'vless') 'uuid': uuid else 'password': 'synthetic-password',
  'tls': {'enabled': true, 'server_name': 'front.example'},
};
ImportResult parse(Map<String, dynamic> node) =>
    const SubscriptionParser().parse(
      jsonEncode({
        'outbounds': [node],
      }),
    );
void rejected(Map<String, dynamic> node) {
  final result = parse(node);
  expect(result.profiles, isEmpty);
  expect(result.issues, isNotEmpty);
  expect(result.issues.toString(), isNot(contains(uuid)));
}

void main() {
  test(
    'typed keepalive survives native projection and changes endpoint identity',
    () {
      final node = xray();
      final previous = parse(node).profiles.single;
      node['streamSettings']['sockopt'] = {
        'tcpKeepAliveIdle': 60,
        'tcpKeepAliveInterval': 20,
      };
      node['streamSettings']['tcpSettings'] = <String, dynamic>{};
      final profile = parse(node).profiles.single;
      expect(profile.transport.tcpKeepAliveIdle, 60);
      expect(
        profile.toNativeJson()['transport'],
        containsPair('tcpKeepAliveInterval', 20),
      );
      expect(profile.id, isNot(previous.id));
      node['streamSettings'].remove('sockopt');
      expect(parse(node).profiles.single.id, previous.id);
    },
  );
  test('only bounded integer keepalive fields can cross socket boundary', () {
    for (final bad in [0, -1, 86401, 1.5, '60', null, true]) {
      rejected(
        xray()..['streamSettings']['sockopt'] = {'tcpKeepAliveIdle': bad},
      );
    }
    for (final key in [
      'mark',
      'interface',
      'dialerProxy',
      'domainStrategy',
      'tcpFastOpen',
    ]) {
      rejected(xray()..['streamSettings']['sockopt'] = {key: 1});
    }
    rejected(
      xray()
        ..['streamSettings']['tcpSettings'] = {
          'header': {'type': 'http'},
        },
    );
  });
  test('Hiddify REALITY TCP and xhttp preserve peer settings and xudp', () {
    for (final xhttp in [false, true]) {
      final node = sing()..['packet_encoding'] = 'xudp';
      node['tls']['utls'] = {'enabled': true, 'fingerprint': 'firefox'};
      node['tls']['reality'] = {
        'enabled': true,
        'public_key': base64Url.encode(List.filled(32, 1)).replaceAll('=', ''),
        'short_id': 'abcd',
      };
      if (xhttp) {
        node['transport'] = {
          'type': 'xhttp',
          'mode': 'auto',
          'host': 'front.example',
          'path': '/',
        };
      } else {
        node['flow'] = 'xtls-rprx-vision';
      }
      final profile = parse(node).profiles.single;
      expect(profile.tls.reality!.shortId, 'abcd');
      expect(profile.tls.fingerprint, 'firefox');
      expect(profile.packetEncoding, 'xudp');
      expect(profile.transport.type, xhttp ? 'xhttp' : 'tcp');
    }
  });
  test(
    'Hiddify WebSocket normalizes ALPN string, host and early data marker',
    () {
      final node = sing()..['packet_encoding'] = 'xudp';
      node['tls']['alpn'] = 'http/1.1';
      node['transport'] = {
        'type': 'ws',
        'path': '/ws',
        'headers': {'Host': 'front.example'},
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      };
      final profile = parse(node).profiles.single;
      expect(profile.tls.alpn, ['http/1.1']);
      expect(profile.transport.host, 'front.example');
      expect(profile.transport.wsEarlyDataHeaderName, 'Sec-WebSocket-Protocol');
      node['transport']['early_data_header_name'] = 'Authorization';
      rejected(node);
    },
  );
  test(
    'Hiddify Hysteria2 requires authenticated TLS and endpoint password',
    () {
      final node = sing(protocol: 'hysteria2');
      final profile = parse(node).profiles.single;
      expect(profile.protocol, ProxyProtocol.hysteria2);
      expect(profile.transport.type, 'hysteria');
      expect(profile.password, 'synthetic-password');
      node['tls'] = {'enabled': false};
      rejected(node);
    },
  );
  test('placeholder records and provider local authority are rejected', () {
    for (final address in ['0.0.0.0', '::', '::0']) {
      rejected(sing()..['server'] = address);
    }
    for (final key in [
      'detour',
      'bind_interface',
      'routing_mark',
      'domain_resolver',
    ]) {
      rejected(sing()..[key] = 'direct');
    }
    final node = sing();
    node['tls']['insecure'] = true;
    rejected(node);
    node['tls']['insecure'] = false;
    node['packet_encoding'] = 'unknown';
    rejected(node);
  });
  test('mixed provider document cannot replace local routes DNS or trust', () {
    final document = {
      'outbounds': [
        sing(),
        {'type': 'direct'},
      ],
      'dns': {
        'servers': ['untrusted.example'],
      },
      'routing': {
        'rules': [
          {'outboundTag': 'direct'},
        ],
      },
      'inbounds': [
        {'listen': '0.0.0.0'},
      ],
    };
    final result = const SubscriptionParser().parse(jsonEncode(document));
    expect(result.profiles, hasLength(1));
    expect(
      result.issues.map((issue) => issue.code),
      contains(ImportIssueCode.ignoredLocalConfiguration),
    );
    expect(
      result.profiles.single.toNativeJson().keys,
      isNot(contains('routing')),
    );
  });
}
