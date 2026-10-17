import 'dart:convert';

import 'package:exvpn/main.dart';
import 'package:exvpn/build_identity.dart';
import 'package:exvpn/src/power_button.dart';
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
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
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

void _expectDisconnected(WidgetTester tester) {
  final power = tester.widget<PowerButton>(
    find.byKey(const Key('connect-button')),
  );
  expect(power.active, isFalse);
  expect(power.connecting, isFalse);
  expect(power.label, 'Подключить VPN');
  expect(find.text('Подключено'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Use the bundled typeface for meaningful responsive layout checks.
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await font.load();
  });

  testWidgets('home shows brief partial-update reason and keeps working list', (
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
    final candidate = controller.pendingUpdate(id);
    expect(candidate, isNotNull);
    expect(candidate!.previousCount, 1);
    expect(candidate.issues.single.index, 2);
    await _open(tester, controller);
    expect(controller.selectedServer!.name, 'Sample');
    expect(find.byKey(const Key('connection-notice')), findsNothing);
    await _tap(tester, find.byKey(ValueKey('subscription-issues-$id')));
    expect(
      find.textContaining('Часть подключений пока не поддерживается.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('accept-partial-subscription')), findsNothing);
    expect(
      find.textContaining('Последний рабочий список сохранён.'),
      findsOneWidget,
    );
    await _tap(tester, find.byKey(const Key('keep-subscription')));
    expect(find.byKey(const Key('subscription-issues-dialog')), findsNothing);
    expect(controller.selectedServer!.name, 'Sample');
    expect(controller.pendingUpdate(id), same(candidate));
    _expectDisconnected(tester);
    expect(find.byKey(ValueKey('subscription-issues-$id')), findsOneWidget);
    expect(find.byKey(const Key('connection-notice')), findsNothing);
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
    _expectDisconnected(tester);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('server-demo-main-demo-frankfurt')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.selected == true &&
              widget.properties.button == true,
        ),
      ),
      findsOneWidget,
    );
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
      final issues = find.byKey(
        ValueKey('subscription-issues-${controller.groups.single.id}'),
      );
      expect(issues, findsOneWidget);
      await _tap(tester, issues);
      expect(
        find.byKey(const Key('subscription-issues-dialog')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Часть подключений пока не поддерживается.'),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic.invalid'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connect explains unavailable native VPN and never claims connected',
    (tester) async {
      await _open(tester, AppController.demo());
      await _tap(tester, find.byKey(const Key('connect-button')));
      expect(find.text('VPN пока недоступен'), findsOneWidget);
      expect(find.text('В этой сборке VPN пока недоступен.'), findsOneWidget);
      _expectDisconnected(tester);
      await _tap(tester, find.text('Понятно'));
      expect(find.byType(AlertDialog), findsNothing);
      _expectDisconnected(tester);
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

  testWidgets('settings omit subscription management and preserve selection', (
    tester,
  ) async {
    final controller = AppController();
    controller.addSubscription(name: 'Temporary', raw: _sampleProfile);
    await _open(tester, controller);
    await _tap(tester, find.byKey(const Key('settings-button')));
    expect(find.byTooltip('Удалить Temporary'), findsNothing);
    expect(find.text('Подписки'), findsNothing);
    expect(find.text('created by БЕЛКА'), findsOneWidget);
    await _tap(tester, find.byTooltip('Закрыть настройки'));
    expect(controller.groups, hasLength(1));
    expect(controller.selectedServer, isNotNull);
    expect(find.byKey(const Key('empty-add-button')), findsNothing);
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
