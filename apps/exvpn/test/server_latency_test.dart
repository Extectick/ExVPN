import 'dart:async';

import 'package:exvpn/services/server_latency.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

ConnectionProfile node(
  String id, {
  String? host,
  ProxyProtocol protocol = ProxyProtocol.vless,
}) => ConnectionProfile(
  id: id,
  name: id,
  protocol: protocol,
  server: host ?? '$id.example.invalid',
  port: 443,
  uuid: '00000000-0000-4000-8000-000000000001',
  transport: const Transport(),
  tls: TlsOptions(enabled: true),
);
const good = ProbeResult(reachable: true, latency: Duration(milliseconds: 42));
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('endpoint aliases share a result; cache reused for five minutes; manual forces refresh', () async {
    var calls = 0;
    var now = DateTime.utc(2026, 10, 20);
    final ping = ServerLatencyController(
      now: () => now,
      probe: (_) async {
        calls++;
        return good;
      },
    );
    addTearDown(ping.dispose);
    final a = node('a', host: 'same.example.invalid');
    final b = node('b', host: 'SAME.example.invalid');
    await ping.checkVisible([a, b]);
    expect(calls, 1);
    expect(ping.results[a.id]!.milliseconds, 42);
    expect(ping.results[b.id]!.milliseconds, 42);
    now = now.add(const Duration(minutes: 4));
    await ping.checkVisible([a]);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 2));
    await ping.checkVisible([a]);
    expect(calls, 2);
    await ping.checkAll([a, b]);
    expect(calls, 3);
  });

  test(
    'two operations at most; scrolling replaces queued offscreen work',
    () async {
      final started = <String>[];
      final pending = <String, Completer<ProbeResult>>{};
      final ping = ServerLatencyController(
        probe: (profile) {
          started.add(profile.id);
          return (pending[profile.id] = Completer<ProbeResult>()).future;
        },
      );
      addTearDown(ping.dispose);
      final profiles = [for (var i = 0; i < 10; i++) node('n$i')];
      final running = ping.checkVisible(profiles);
      await tick();
      expect(started, ['n0', 'n1']);
      final replacement = ping.checkVisible([profiles.last]);
      pending['n0']!.complete(good);
      pending['n1']!.complete(good);
      await tick();
      expect(started, ['n0', 'n1', 'n9']);
      pending['n9']!.complete(good);
      await running;
      await replacement;
      expect(ping.results.keys, ['n9']);
      expect(ping.checking, isEmpty);
    },
  );

  test(
    'pause starts no more work; disposed controller settles its own deadlines',
    () async {
      var active = true;
      var calls = 0;
      final pending = <Completer<ProbeResult>>[];
      final ping = ServerLatencyController(
        canProbe: () => active,
        probe: (_) {
          calls++;
          final operation = Completer<ProbeResult>();
          pending.add(operation);
          return operation.future;
        },
      );
      final running = ping.checkVisible([
        for (var i = 0; i < 8; i++) node('p$i'),
      ]);
      await tick();
      expect(calls, 2);
      active = false;
      ping.pause();
      for (final operation in pending) {
        operation.complete(good);
      }
      await running;
      expect(calls, 2);
      await ping.checkVisible([node('background')]);
      expect(calls, 2);
      active = true;
      final disposing = ping.checkVisible([node('last')]);
      await tick();
      ping.dispose();
      await disposing;
      pending.last.completeError(StateError('private exception'));
      await tick();
    },
  );

  test(
    'short failure cache, bounded storage and no bogus UDP measurement',
    () async {
      var calls = 0;
      var now = DateTime.utc(2026, 10, 20);
      var response = const ProbeResult(
        reachable: false,
        errorCode: 'raw secret',
      );
      final ping = ServerLatencyController(
        now: () => now,
        probe: (_) async {
          calls++;
          return response;
        },
      );
      addTearDown(ping.dispose);
      final a = node('a');
      await ping.checkVisible([a]);
      expect(ping.results[a.id]!.errorCode, 'latency_failed');
      now = now.add(const Duration(seconds: 20));
      await ping.checkVisible([a]);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 11));
      response = good;
      await ping.checkVisible([a]);
      expect(calls, 2);
      await ping.checkVisible([node('udp', protocol: ProxyProtocol.hysteria2)]);
      expect(calls, 2);
      expect(ping.results['udp']!.errorCode, 'latency_transport_unsupported');
      await ping.checkAll([for (var i = 0; i < 520; i++) node('cache$i')]);
      expect(ping.results.length, lessThanOrEqualTo(512));
      final before = calls;
      await ping.checkVisible([node('cache519')]);
      expect(calls, before);
      await ping.checkVisible([node('cache0')]);
      expect(calls, before + 1);
    },
  );
}
