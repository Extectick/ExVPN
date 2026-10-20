// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/site_routing_presets.dart';
import 'package:exvpn/src/site_routing_sheet.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge, running;

class SiteBridge extends FakeBridge implements SiteRoutingBridge {
  SiteRoutingState state = SiteRoutingState.disabled();
  final writes = <SiteRoutingState>[];
  Completer<void>? blockedWrite;
  bool failWrite = false;

  @override
  Future<SiteRoutingState> getSiteRouting() async => state;
  @override
  Future<void> setSiteRouting(SiteRoutingState value) async {
    await blockedWrite?.future;
    if (failWrite) throw const VpnFailure('native_storage_unavailable');
    state = SiteRoutingState.fromJson(value.toJson());
    writes.add(state);
  }
}

Future<void> openSites(WidgetTester tester, SiteBridge bridge) async {
  final vpn = VpnController(bridge);
  await vpn.initialize();
  addTearDown(() async {
    vpn.dispose();
    await bridge.close();
  });
  tester.view.physicalSize = const Size(380, 440);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SiteRoutingSheet(vpn: vpn),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all shipped presets fit the strict native contract', () {
    expect(builtInSitePresets.first.policy.mode, SiteRoutingMode.include);
    for (final preset in builtInSitePresets) {
      final roundTrip = SiteRoutingState.fromJson(
        SiteRoutingState(
          policy: preset.policy,
          selectedPreset: preset.id,
        ).toJson(),
      );
      expect(roundTrip.policy.rules, isNotEmpty);
      expect(
        roundTrip.policy.rules.toSet().length,
        roundTrip.policy.rules.length,
      );
    }
  });

  test(
    'pending durable save blocks a new connection and retains state on failure',
    () async {
      final bridge = SiteBridge()..blockedWrite = Completer<void>();
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await vpn.initialize();
      final previous = await vpn.loadSiteRouting();
      final changed = SiteRoutingState(policy: builtInSitePresets.first.policy);
      final writing = vpn.setSiteRouting(changed);
      expect(vpn.commandPending, isTrue);
      expect(vpn.siteRouting, same(previous));
      bridge.failWrite = true;
      final failure = expectLater(writing, throwsA(isA<VpnFailure>()));
      bridge.blockedWrite!.complete();
      await failure;
      expect(vpn.commandPending, isFalse);
      expect(vpn.siteRouting, same(previous));
      expect(bridge.writes, isEmpty);
    },
  );

  test(
    'legacy bridge refuses optional policy rather than saving only in UI',
    () async {
      final bridge = FakeBridge();
      final vpn = VpnController(bridge);
      addTearDown(() async {
        vpn.dispose();
        await bridge.close();
      });
      await expectLater(vpn.loadSiteRouting(), throwsA(isA<VpnFailure>()));
      await expectLater(
        vpn.setSiteRouting(SiteRoutingState.disabled()),
        throwsA(isA<VpnFailure>()),
      );
      expect(vpn.siteRouting, isNull);
    },
  );

  testWidgets(
    'Russia is an explicit draft; compact search stays fixed while scrolling',
    (tester) async {
      final bridge = SiteBridge();
      await openSites(tester, bridge);
      expect(bridge.writes, isEmpty);
      expect(bridge.state.policy.mode, SiteRoutingMode.disabled);
      final searchY = tester
          .getTopLeft(find.byKey(const Key('site-search')))
          .dy;
      await tester.drag(
        find.byKey(const Key('site-rule-list')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('site-search'))).dy,
        searchY,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('site-routing-save')));
      await tester.pumpAndSettle();
      expect(bridge.writes.single.policy.mode, SiteRoutingMode.include);
      expect(
        bridge.writes.single.policy.rules,
        builtInSitePresets.first.policy.rules,
      );
      expect(find.byType(SiteRoutingSheet), findsNothing);
    },
  );

  testWidgets('saving a preset preserves the applied policy', (tester) async {
    final bridge = SiteBridge();
    await openSites(tester, bridge);
    await tester.tap(find.byKey(const Key('site-save-preset')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('site-preset-name')),
      'Мой список',
    );
    await tester.tap(find.byKey(const Key('site-preset-confirm')));
    await tester.pumpAndSettle();
    expect(bridge.writes.single.policy.mode, SiteRoutingMode.disabled);
    expect(bridge.state.savedPresets.single.name, 'Мой список');
    expect(
      bridge.state.savedPresets.single.policy.mode,
      SiteRoutingMode.include,
    );
    expect(find.byType(SiteRoutingSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid batch never partially changes rules; URLs and CIDRs canonicalize',
    (tester) async {
      final bridge = SiteBridge()
        ..state = SiteRoutingState(
          policy: SiteRoutingPolicy(
            mode: SiteRoutingMode.exclude,
            rules: ['safe.example'],
          ),
          selectedPreset: '',
        );
      await openSites(tester, bridge);
      Future<void> add(String text) async {
        await tester.tap(find.byKey(const Key('site-add')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('site-address-input')),
          text,
        );
        await tester.tap(find.byKey(const Key('site-add-confirm')));
        await tester.pumpAndSettle();
      }

      await add('good.example bad:input');
      expect(
        find.byKey(const ValueKey('site-rule-good.example')),
        findsNothing,
      );
      await add('https://EXAMPLE.com/path 192.0.2.129/24 example.com');
      await tester.tap(find.byKey(const Key('site-routing-save')));
      await tester.pumpAndSettle();
      expect(bridge.state.policy.rules, [
        'safe.example',
        'example.com',
        '192.0.2.0/24',
      ]);
    },
  );

  testWidgets('active connection disallows changes', (tester) async {
    final bridge = SiteBridge()..current = running();
    await openSites(tester, bridge);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('site-routing-save')))
          .onPressed,
      isNull,
    );
    expect(bridge.writes, isEmpty);
  });

  testWidgets('failed native save retains the visible draft for retry', (
    tester,
  ) async {
    final bridge = SiteBridge()..failWrite = true;
    await openSites(tester, bridge);
    await tester.tap(find.byKey(const Key('site-routing-save')));
    await tester.pumpAndSettle();
    expect(find.byType(SiteRoutingSheet), findsOneWidget);
    expect(bridge.writes, isEmpty);
    bridge.failWrite = false;
    await tester.tap(find.byKey(const Key('site-routing-save')));
    await tester.pumpAndSettle();
    expect(
      bridge.writes.single.policy.rules,
      builtInSitePresets.first.policy.rules,
    );
  });

  test(
    'native bridge uses strict channel DTO and rejects malformed reads',
    () async {
      const channel = MethodChannel('test/site-routing');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      Object? response = SiteRoutingState.disabled().toJson();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return response;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final bridge = NativeVpnBridge(methods: channel);
      expect(
        (await bridge.getSiteRouting()).policy.mode,
        SiteRoutingMode.disabled,
      );
      final state = SiteRoutingState(policy: builtInSitePresets.first.policy);
      await bridge.setSiteRouting(state);
      expect(calls.last.method, 'setSiteRouting');
      expect(calls.last.arguments, state.toJson());
      response = {
        'schema': 1,
        'policy': {'mode': 'include', 'rules': null},
        'savedPresets': [],
        'selectedPreset': '',
      };
      await expectLater(bridge.getSiteRouting(), throwsA(isA<VpnFailure>()));
    },
  );
}
