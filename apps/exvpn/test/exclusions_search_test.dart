import 'dart:async';
import 'dart:typed_data';

import 'package:exvpn/services/native_vpn_bridge.dart';
import 'package:exvpn/services/vpn_controller.dart';
import 'package:exvpn/src/app_strings.dart';
import 'package:exvpn/src/exclusions_sheet.dart';
import 'package:exvpn/src/sliding_segments.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

const protectedId = 'ru.exvpn.netprobe';
const excludedId = 'ru.exvpn.netprobe.excluded';
const hiddenId = 'com.example.hidden';
const removedId = 'C:/Removed/example.exe';
const searchKey = Key('exclusions-search');
const countKey = Key('exclusions-selected-count');

class SearchPolicyBridge extends FakeBridge
    implements ApplicationRoutingBridge, ApplicationIconBridge {
  ApplicationRoutingMode routingMode = ApplicationRoutingMode.exclude;
  ApplicationRoutingPolicy? savedRouting;
  final iconReads = <String>[];
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

  @override
  Future<ApplicationRoutingPolicy> getApplicationRouting() async =>
      ApplicationRoutingPolicy(
        mode: routingMode,
        applicationIds: await getExclusions(),
      );

  @override
  Future<void> setApplicationRouting(ApplicationRoutingPolicy policy) async {
    await setExclusions(policy.applicationIds);
    routingMode = policy.mode;
    savedRouting = policy;
  }

  @override
  Future<Uint8List?> getApplicationIcon(String id) async {
    iconReads.add(id);
    return null;
  }
}

class SlowIconBridge extends SearchPolicyBridge {
  final pendingIcons = <Completer<Uint8List?>>[];
  int activeIcons = 0;
  int maxActiveIcons = 0;
  @override
  Future<Uint8List?> getApplicationIcon(String id) {
    iconReads.add(id);
    activeIcons++;
    if (activeIcons > maxActiveIcons) maxActiveIcons = activeIcons;
    final done = Completer<Uint8List?>();
    pendingIcons.add(done);
    return done.future.whenComplete(() => activeIcons--);
  }
}

Future<void> openExclusions(
  WidgetTester tester,
  SearchPolicyBridge bridge,
) async {
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
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
      theme: ThemeData(fontFamily: 'Inter'),
      supportedLocales: appSupportedLocales,
      localeListResolutionCallback: resolveAppLocale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
  setUpAll(() async {
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await font.load();
  });
  testWidgets(
    'routing choices fit the 400 by 440 desktop window and keep full tooltips',
    (tester) async {
      final bridge = SearchPolicyBridge();
      await openExclusions(tester, bridge);
      await tester.binding.setSurfaceSize(const Size(400, 440));
      await tester.pumpAndSettle();
      for (final label in ['Выключено', 'Исключения', 'Только эти']) {
        final text = find.text(label);
        expect(text.hitTestable(), findsOneWidget);
        expect(
          tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse,
        );
      }
      expect(
        find.byTooltip('VPN для всех, кроме выбранных приложений'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('VPN только для выбранных приложений'),
        findsOneWidget,
      );
      await tester.tap(find.text('Только эти'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SlidingSegments<ApplicationRoutingMode>>(
              find.byKey(const Key('application-routing-mode')),
            )
            .value,
        ApplicationRoutingMode.include,
      );
      expect(find.byKey(searchKey).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(find.text('Protected probe'), findsOneWidget);
    expect(find.text('Excluded probe'), findsOneWidget);
    expect(find.text(protectedId), findsNothing);
    expect(find.text(excludedId), findsNothing);

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

  testWidgets(
    'disabled routing keeps selected applications without applying them',
    (tester) async {
      final bridge = SearchPolicyBridge()..excluded = {hiddenId, removedId};
      await openExclusions(tester, bridge);
      await tester.tap(find.text('Выключено'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SlidingSegments<ApplicationRoutingMode>>(
              find.byKey(const Key('application-routing-mode')),
            )
            .value,
        ApplicationRoutingMode.disabled,
      );
      await tester.tap(find.byKey(const Key('application-routing-save')));
      await tester.pumpAndSettle();
      expect(bridge.savedRouting!.mode, ApplicationRoutingMode.disabled);
      expect(bridge.savedRouting!.applicationIds, {hiddenId, removedId});
    },
  );

  testWidgets('include routing saves exactly the selected applications', (
    tester,
  ) async {
    final bridge = SearchPolicyBridge()..excluded = {hiddenId};
    await openExclusions(tester, bridge);
    await tester.tap(find.text('Только выбранные'));
    await tester.enterText(find.byKey(searchKey), protectedId);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protected probe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('application-routing-save')));
    await tester.pumpAndSettle();
    expect(bridge.savedRouting!.mode, ApplicationRoutingMode.include);
    expect(bridge.savedRouting!.applicationIds, {hiddenId, protectedId});
  });

  testWidgets(
    'clear-all cancellation preserves selection and confirmation clears only the draft',
    (tester) async {
      final bridge = SearchPolicyBridge()..excluded = {hiddenId};
      await openExclusions(tester, bridge);
      await tester.tap(find.byKey(const Key('exclusions-clear-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.text('Выбрано всего: 1'), findsOneWidget);
      expect(bridge.excluded, {hiddenId});
      expect(bridge.writes, isEmpty);
      await tester.tap(find.byKey(const Key('exclusions-clear-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Очистить'));
      await tester.pumpAndSettle();
      expect(find.text('Выбрано всего: 0'), findsOneWidget);
      expect(bridge.excluded, {hiddenId});
      expect(bridge.writes, isEmpty);
      await tester.tap(find.byKey(const Key('application-routing-save')));
      await tester.pumpAndSettle();
      expect(bridge.savedRouting!.applicationIds, isEmpty);
    },
  );

  testWidgets(
    'search and mode remain pinned while the lazy app list requests at most three icons',
    (tester) async {
      final bridge = SlowIconBridge()
        ..applications = [
          for (var i = 0; i < 1000; i++)
            ApplicationIdentity(
              id: 'example.app$i',
              displayName: 'Application $i',
            ),
        ];
      await openExclusions(tester, bridge);
      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(30));
      expect(bridge.iconReads.length, 3);
      final searchRect = tester.getRect(find.byKey(searchKey));
      final modesRect = tester.getRect(
        find.byKey(const Key('application-routing-mode')),
      );
      await tester.drag(
        find.byKey(const Key('exclusions-app-list')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(searchKey)), searchRect);
      expect(
        tester.getRect(find.byKey(const Key('application-routing-mode'))),
        modesRect,
      );
      expect(find.byKey(searchKey).hitTestable(), findsOneWidget);
      expect(bridge.iconReads.length, 3);
      // A UI timeout must not release a still-running native request's slot.
      await tester.pump(const Duration(seconds: 4));
      expect(bridge.iconReads.length, 3);
      for (final request in bridge.pendingIcons.toList()) {
        request.complete();
      }
      await tester.pumpAndSettle();
      expect(bridge.maxActiveIcons, 3);
      expect(bridge.iconReads.length, 6);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable Windows selections show a basename while preserving their exact stored ID',
    (tester) async {
      const privatePath = r'C:\Users\private-user\Apps\Missing\missing.exe';
      final bridge = SearchPolicyBridge()..excluded = {privatePath};
      await openExclusions(tester, bridge);
      expect(find.text('missing.exe'), findsOneWidget);
      expect(find.text(privatePath), findsNothing);
      expect(find.textContaining('private-user'), findsNothing);
      await tester.tap(find.byKey(const Key('application-routing-save')));
      await tester.pumpAndSettle();
      expect(bridge.savedRouting!.applicationIds, {privatePath});
    },
  );
}
