import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/exclusions_sheet.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

const protectedId = 'ru.exvpn.netprobe';
const excludedId = 'ru.exvpn.netprobe.excluded';
const hiddenId = 'com.example.hidden';
const removedId = 'C:/Removed/example.exe';
const searchKey = Key('exclusions-search');
const countKey = Key('exclusions-selected-count');

class SearchPolicyBridge extends FakeBridge {
  final writes = <Set<String>>[];
  int applicationReads = 0;
  bool listFails = false;
  bool writeFails = false;
  List<ApplicationIdentity> applications = const [
    ApplicationIdentity(id: protectedId, displayName: 'Protected probe'),
    ApplicationIdentity(id: excludedId, displayName: 'Excluded probe'),
    ApplicationIdentity(id: hiddenId, displayName: 'Hidden selection'),
    ApplicationIdentity(
      id: r'C:\Apps\Browser\browser.exe',
      displayName: 'Браузер',
    ),
    ApplicationIdentity(
      id: 'com.example.shared',
      displayName: 'Shared system app',
      sharedIdentityGroup: 'synthetic-shared-owner',
    ),
  ];

  @override
  Future<List<ApplicationIdentity>> listApplications() async {
    applicationReads++;
    if (listFails) throw const VpnFailure('exclusions_unavailable');
    return applications;
  }

  @override
  Future<void> setExclusions(Set<String> ids) async {
    writes.add(Set.of(ids));
    if (writeFails) throw const VpnFailure('native_storage_unavailable');
    await super.setExclusions(ids);
  }
}

Future<void> openExclusions(
  WidgetTester tester,
  SearchPolicyBridge bridge,
) async {
  await tester.binding.setSurfaceSize(const Size(800, 900));
  final vpn = VpnController(bridge);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    vpn.dispose();
    await bridge.close();
    await tester.binding.setSurfaceSize(null);
  });
  await vpn.initialize();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ExclusionsSheet(vpn: vpn),
              ),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search remains usable on a phone with the keyboard open', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()..excluded = {hiddenId};
    await openExclusions(tester, bridge);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    tester.view.viewInsets = FakeViewPadding(
      bottom: 280 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(find.byKey(searchKey), excludedId);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Выбрано всего: 1'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Excluded probe'),
      120,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
      maxScrolls: 5,
    );
    await tester.pumpAndSettle();
    expect(find.text('Excluded probe').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Excluded probe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(bridge.writes.single, {hiddenId, excludedId});
  });

  testWidgets('search matches name, Android package and Windows path locally', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge();
    await openExclusions(tester, bridge);

    await tester.enterText(find.byKey(searchKey), '  бРАУЗЕР  ');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('Браузер'), findsOneWidget);

    await tester.enterText(find.byKey(searchKey), 'RU.EXVPN.NETPROBE');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text(protectedId), findsOneWidget);
    expect(find.text(excludedId), findsOneWidget);

    await tester.enterText(find.byKey(searchKey), r'c:\apps\browser');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.text('Браузер'), findsOneWidget);
    expect(find.text('Выбрано всего: 0'), findsOneWidget);
    expect(bridge.applicationReads, 1);
    expect(bridge.writes, isEmpty);
  });

  testWidgets('filter and toggle preserve hidden and unavailable selections', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()..excluded = {hiddenId, removedId};
    await openExclusions(tester, bridge);
    expect(find.text('Выбрано всего: 2'), findsOneWidget);

    await tester.enterText(find.byKey(searchKey), 'ru.exvpn.netprobe');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Excluded probe'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано всего: 3'), findsOneWidget);
    expect(find.text('Hidden selection'), findsNothing);
    expect(find.text(removedId), findsNothing);

    await tester.enterText(find.byKey(searchKey), 'Protected probe');
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    expect(find.text('Выбрано всего: 3'), findsOneWidget);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(bridge.writes.single, {hiddenId, removedId, excludedId});
    expect(bridge.excluded, {hiddenId, removedId, excludedId});
    expect(find.byType(ExclusionsSheet), findsNothing);
  });

  testWidgets('no results keeps the total and saves the hidden selection', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()..excluded = {hiddenId};
    await openExclusions(tester, bridge);
    await tester.enterText(find.byKey(searchKey), 'no-such-application');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Выбрано всего: 1'), findsOneWidget);
    expect(bridge.writes, isEmpty);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(bridge.writes.single, {hiddenId});
  });

  testWidgets('shared system identities remain disabled after filtering', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge();
    await openExclusions(tester, bridge);
    await tester.enterText(find.byKey(searchKey), 'com.example.shared');
    await tester.pumpAndSettle();
    final tile = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    expect(
      find.text('Общий системный UID · исключение недоступно'),
      findsOneWidget,
    );
    expect(bridge.writes, isEmpty);
  });

  testWidgets('active VPN keeps checkboxes and save disabled while searching', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()
      ..current = const VpnStatus(
        phase: VpnPhase.blocked,
        processCrashProtection: false,
      );
    await openExclusions(tester, bridge);
    await tester.enterText(find.byKey(searchKey), excludedId);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить'))
          .onPressed,
      isNull,
    );
    expect(find.text('Сначала отключите VPN.'), findsOneWidget);
    expect(bridge.writes, isEmpty);
  });

  testWidgets('failed inventory does not show a false zero selected count', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()
      ..excluded = {hiddenId}
      ..listFails = true;
    await openExclusions(tester, bridge);
    expect(find.text('Список недоступен'), findsOneWidget);
    expect(find.byKey(searchKey), findsNothing);
    expect(find.byKey(countKey), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Сохранить'))
          .onPressed,
      isNull,
    );
    expect(bridge.writes, isEmpty);
    expect(bridge.excluded, {hiddenId});
  });

  testWidgets(
    'save error retains filter and hidden selection without claiming success',
    (tester) async {
      final bridge = SearchPolicyBridge()
        ..excluded = {hiddenId}
        ..writeFails = true;
      await openExclusions(tester, bridge);
      await tester.enterText(find.byKey(searchKey), excludedId);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Excluded probe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ExclusionsSheet), findsOneWidget);
      expect(
        find.textContaining('Не удалось прочитать или сохранить'),
        findsOneWidget,
      );
      expect(find.text('Выбрано всего: 2'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(searchKey)).controller!.text,
        excludedId,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      expect(bridge.writes.single, {hiddenId, excludedId});
      expect(bridge.excluded, {hiddenId});
    },
  );
}
