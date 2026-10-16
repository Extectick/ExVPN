import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/exclusions_sheet.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

class BrokenPolicyBridge extends FakeBridge {
  bool unreadable = true;
  bool writeFails = false;
  int writes = 0;
  @override
  Future<Set<String>> getExclusions() async {
    if (unreadable) throw const VpnFailure('exclusions_unavailable');
    return super.getExclusions();
  }

  @override
  Future<void> setExclusions(Set<String> ids) async {
    writes++;
    if (writeFails) throw const VpnFailure('native_storage_unavailable');
    await super.setExclusions(ids);
    unreadable = false;
  }
}

void main() {
  testWidgets(
    'failed policy read never saves empty settings; explicit reset recovers',
    (tester) async {
      final bridge = BrokenPolicyBridge()..excluded = {'C:/Apps/example.exe'};
      final vpn = VpnController(bridge);
      await vpn.initialize();
      await tester.pumpWidget(MaterialApp(home: ExclusionsSheet(vpn: vpn)));
      await tester.pumpAndSettle();
      expect(find.text('Список недоступен'), findsOneWidget);
      expect(bridge.writes, 0);
      expect(bridge.excluded, isNotEmpty);
      await tester.tap(find.byKey(const Key('reset-exclusions')));
      await tester.pumpAndSettle();
      expect(bridge.writes, 1);
      expect(bridge.excluded, isEmpty);
      expect(vpn.exclusions, isEmpty);
      expect(find.text('Список недоступен'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      vpn.dispose();
      await bridge.close();
    },
  );

  testWidgets('reset cannot bypass an active guard or hide a write failure', (
    tester,
  ) async {
    final bridge = BrokenPolicyBridge()..writeFails = true;
    bridge.current = const VpnStatus(
      phase: VpnPhase.blocked,
      processCrashProtection: false,
    );
    final vpn = VpnController(bridge);
    await vpn.initialize();
    await tester.pumpWidget(MaterialApp(home: ExclusionsSheet(vpn: vpn)));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('reset-exclusions')))
          .onPressed,
      isNull,
    );
    expect(bridge.writes, 0);
    await vpn.disconnect();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: ExclusionsSheet(vpn: vpn)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-exclusions')));
    await tester.pumpAndSettle();
    expect(bridge.writes, 1);
    expect(find.text('Список недоступен'), findsOneWidget);
    expect(
      find.textContaining('Не удалось прочитать или сохранить'),
      findsOneWidget,
    );
    expect(bridge.unreadable, isTrue);
    await tester.pumpWidget(const SizedBox());
    vpn.dispose();
    await bridge.close();
  });
}
