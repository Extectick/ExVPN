import 'dart:convert';

import 'package:exvpn/main.dart';
import 'package:exvpn/build_identity.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleProfile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443'
    '?security=tls#Sample';

Future<void> _open(
  WidgetTester tester,
  AppController controller, {
  Size viewport = const Size(426, 922),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(ExVpnApp(controller: controller));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _importText(
  WidgetTester tester, {
  required String name,
  required String raw,
}) async {
  await _tap(tester, find.byKey(const Key('add-button')));
  await _tap(tester, find.text('Текст'));
  await tester.enterText(find.byKey(const Key('subscription-name')), name);
  await tester.enterText(find.byKey(const Key('subscription-input')), raw);
  await _tap(tester, find.byKey(const Key('import-submit')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use the bundled typeface for meaningful responsive layout checks.
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await font.load();
  });

  testWidgets('home exposes partial update reasons and explicit replacement', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    final id = controller
        .addSubscription(name: 'Example', raw: _sampleProfile)
        .groupId;
    controller.updateSubscription(
      groupId: id,
      raw:
          '${_sampleProfile.replaceFirst('000000000001', '000000000002').replaceFirst('#Sample', '#New')}\nunknown://invalid',
    );
    await _open(tester, controller);
    expect(controller.selectedServer!.name, 'Sample');
    await _tap(tester, find.byKey(ValueKey('subscription-issues-$id')));
    expect(find.textContaining('Запись 2: Протокол'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('accept-partial-subscription')));
    expect(controller.selectedServer!.name, 'New');
    expect(find.text('Не подключено'), findsOneWidget);
    expect(find.textContaining('Замечания к подписке: 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsing and reopening a subscription preserves selection', (
    tester,
  ) async {
    final controller = AppController.demo();
    await _open(tester, controller);
    final selectedId = controller.selectedServerId;
    expect(find.text('Амстердам'), findsOneWidget);
    expect(find.text('Париж'), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('group-demo-main')));
    expect(find.text('Амстердам'), findsNothing);
    expect(controller.selectedServerId, selectedId);
    expect(controller.groups.first.expanded, isFalse);

    await _tap(tester, find.byKey(const ValueKey('group-demo-main')));
    expect(find.text('Амстердам'), findsOneWidget);
    expect(controller.selectedServerId, selectedId);
    await _tap(tester, find.byKey(const ValueKey('group-demo-backup')));
    expect(find.text('Париж'), findsOneWidget);
    expect(find.text('Стокгольм'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server selection changes without claiming a VPN connection', (
    tester,
  ) async {
    final controller = AppController.demo();
    await _open(tester, controller);
    await _tap(
      tester,
      find.byKey(const ValueKey('server-demo-main-demo-frankfurt')),
    );
    expect(controller.selectedServer!.name, 'Франкфурт');
    expect(find.text('Не подключено'), findsOneWidget);
    expect(find.text('Подключено'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus opens import while populated lists omit the large CTA', (
    tester,
  ) async {
    await _open(tester, AppController.demo());
    expect(find.byKey(const Key('empty-add-button')), findsNothing);
    final refresh = tester.getCenter(find.byKey(const Key('refresh-button')));
    final add = tester.getCenter(find.byKey(const Key('add-button')));
    expect(refresh.dx, lessThan(add.dx));
    expect(refresh.dy, add.dy);
    await _tap(tester, find.byKey(const Key('add-button')));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('subscription-name')), findsOneWidget);
    expect(find.byKey(const Key('subscription-input')), findsOneWidget);
    expect(find.textContaining('только до закрытия'), findsOneWidget);
    await _tap(tester, find.text('Отмена'));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'first subscription imported through text removes the empty CTA',
    (tester) async {
      final controller = AppController();
      await _open(tester, controller);
      expect(find.byKey(const Key('empty-add-button')), findsOneWidget);
      await _importText(tester, name: 'Test subscription', raw: _sampleProfile);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const Key('empty-add-button')), findsNothing);
      expect(find.text('Test subscription'), findsOneWidget);
      expect(find.text('Sample'), findsOneWidget);
      expect(controller.selectedServer!.latencyMs, isNull);
      expect(controller.isDemo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed import is an existing error group rather than empty state',
    (tester) async {
      final controller = AppController();
      await _open(tester, controller);
      await _importText(
        tester,
        name: 'Broken subscription',
        raw: 'unsupported://synthetic.invalid',
      );
      expect(controller.groups, hasLength(1));
      expect(controller.groups.single.issues, isNotEmpty);
      expect(find.byKey(const Key('empty-add-button')), findsNothing);
      expect(find.text('Broken subscription'), findsOneWidget);
      expect(
        find.text('В подписке пока нет доступных подключений'),
        findsOneWidget,
      );
      expect(find.textContaining('Замечания к подписке:'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connect explains unavailable native VPN and never claims connected',
    (tester) async {
      await _open(tester, AppController.demo());
      await _tap(tester, find.byKey(const Key('connect-button')));
      expect(find.text('VPN пока недоступен'), findsOneWidget);
      expect(
        find.textContaining('защита трафика не включается'),
        findsOneWidget,
      );
      expect(find.text('Подключено'), findsNothing);
      expect(find.text('Не подключено'), findsOneWidget);
      await _tap(tester, find.text('Понятно'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Не подключено'), findsOneWidget);
    },
  );

  testWidgets('connect with no subscription starts import', (tester) async {
    await _open(tester, AppController());
    await _tap(tester, find.byKey(const Key('connect-button')));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(const Key('subscription-name')), findsOneWidget);
    expect(find.text('VPN пока недоступен'), findsNothing);
  });

  testWidgets('light theme switches through settings and keeps selection', (
    tester,
  ) async {
    final controller = AppController.demo();
    await _open(tester, controller);
    final selected = controller.selectedServerId;
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await _tap(tester, find.byKey(const Key('settings-button')));
    await _tap(tester, find.text('Светлая'));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    await _tap(tester, find.byTooltip('Закрыть настройки'));
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    expect(controller.selectedServerId, selected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting subscriptions from settings restores the empty CTA', (
    tester,
  ) async {
    final controller = AppController();
    controller.addSubscription(name: 'Temporary', raw: _sampleProfile);
    await _open(tester, controller);
    await _tap(tester, find.byKey(const Key('settings-button')));
    await _tap(tester, find.byTooltip('Удалить Temporary'));
    expect(find.text('Удалить подписку?'), findsOneWidget);
    await _tap(tester, find.text('Удалить'));
    await _tap(tester, find.byTooltip('Закрыть настройки'));
    expect(controller.groups, isEmpty);
    expect(controller.selectedServer, isNull);
    expect(find.byKey(const Key('empty-add-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diagnostics copies only the preview after explicit action', (
    tester,
  ) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final controller = AppController()
      ..addSubscription(name: 'PRIVATE_SUBSCRIPTION_NAME', raw: _sampleProfile);
    await _open(tester, controller);
    await _tap(tester, find.byKey(const Key('settings-button')));
    await tester.scrollUntilVisible(
      find.text('Обезличенная диагностика'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await _tap(tester, find.text('Обезличенная диагностика'));
    expect(copied, isNull);
    final preview = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(preview, isNot(contains('PRIVATE_SUBSCRIPTION_NAME')));
    expect(preview, isNot(contains('sample.invalid')));
    expect(preview, isNot(contains('00000000-0000-4000-8000-000000000001')));
    expect((jsonDecode(preview) as Map)['version'], appVersionLabel);
    await _tap(tester, find.text('Копировать'));
    expect(copied, preview);
    expect(find.text('Отчёт скопирован'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 426.0, 1280.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'layout at width $width and text scale $scale has no overflow',
        (tester) async {
          await _open(
            tester,
            AppController.demo(),
            viewport: Size(width, 922),
            textScale: scale,
          );
          expect(tester.takeException(), isNull, reason: 'Home layout');
          await _tap(tester, find.byKey(const ValueKey('group-demo-backup')));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Expanded group layout',
          );
          await _tap(tester, find.byKey(const Key('settings-button')));
          expect(tester.takeException(), isNull, reason: 'Settings layout');
          await _tap(tester, find.byTooltip('Закрыть настройки'));
          await _tap(tester, find.byKey(const Key('add-button')));
          expect(tester.takeException(), isNull, reason: 'Import layout');
          await _tap(tester, find.text('Текст'));
          expect(tester.takeException(), isNull, reason: 'Text import layout');
        },
      );
    }
  }
}
