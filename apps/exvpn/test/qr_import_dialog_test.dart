import 'dart:async';

import 'package:exvpn/services/qr_import.dart';
import 'package:exvpn/services/subscription_loader.dart';
import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn/src/sliding_segments.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

const _profile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443'
    '?security=tls#QR%20Sample';

Future<void> _open(
  WidgetTester tester,
  AppController controller,
  Future<String?> Function() reader, {
  Future<SubscriptionDocument> Function(String)? documentLoader,
}) async {
  tester.view.physicalSize = const Size(426, 922);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ImportDialog(
                controller: controller,
                qrReader: reader,
                documentLoader: documentLoader,
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

Future<void> _openQrMenu(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(SlidingSegments<String>),
      matching: find.text('QR'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('qr-import-button')));
  await tester.pumpAndSettle();
}

Future<void> _read(WidgetTester tester, {String source = 'file'}) async {
  await _openQrMenu(tester);
  await tester.tap(
    find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == source,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _textMode(WidgetTester tester) async {
  await tester.tap(find.text('Текст'));
  await tester.pumpAndSettle();
}

String _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('subscription-input')))
    .controller!
    .text;

void main() {
  testWidgets('name is optional and imported body metadata names the group', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await _open(
      tester,
      controller,
      () async => '#profile-title: Provider VPN\n$_profile',
    );
    await _read(tester);
    await tester.ensureVisible(find.byKey(const Key('import-submit')));
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pumpAndSettle();
    expect(controller.groups.single.name, 'Provider VPN');
    expect(controller.groups.single.nameIsAutomatic, isTrue);
    expect(controller.groups.single.servers, hasLength(1));
    expect(find.byType(ImportDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR text is previewed and imported only after confirmation', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await _open(tester, controller, () async => _profile);
    await tester.enterText(find.byKey(const Key('subscription-name')), 'QR QA');
    await _read(tester);
    expect(_input(tester), _profile);
    expect(controller.groups, isEmpty);
    expect(
      find.text('QR-код прочитан. Проверьте данные и подтвердите импорт.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SlidingSegments<String>>(find.byType(SlidingSegments<String>))
          .value,
      'text',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pumpAndSettle();
    expect(controller.groups, hasLength(1));
    expect(controller.groups.single.servers.single.name, 'QR Sample');
    expect(find.byType(ImportDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'HTTPS QR fills link mode without importing before confirmation',
    (tester) async {
      final controller = AppController();
      addTearDown(controller.dispose);
      const url = 'https://example.invalid/sub/synthetic-test';
      await _open(
        tester,
        controller,
        () async => url,
        documentLoader: (_) async => const SubscriptionDocument(body: _profile),
      );
      await _read(tester);
      expect(_input(tester), url);
      expect(controller.groups, isEmpty);
      expect(
        tester
            .widget<SlidingSegments<String>>(
              find.byType(SlidingSegments<String>),
            )
            .value,
        'link',
      );
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(controller.groups, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker cancellation and decoding error preserve typed input', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    var attempt = 0;
    await _open(tester, controller, () async {
      if (attempt++ == 0) return null;
      throw const QrImportException(QrImportError.notFound);
    });
    await _textMode(tester);
    await tester.enterText(
      find.byKey(const Key('subscription-input')),
      _profile,
    );
    await _read(tester);
    await _textMode(tester);
    expect(_input(tester), _profile);
    await _read(tester);
    expect(
      find.text('QR-код не найден. Выберите чёткое изображение с одним кодом.'),
      findsOneWidget,
    );
    await _textMode(tester);
    expect(_input(tester), _profile);
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending picker disables duplicate reads and submit', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    final pending = Completer<String?>();
    var reads = 0;
    await _open(tester, controller, () {
      reads++;
      return pending.future;
    });
    await _openQrMenu(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String> && widget.value == 'file',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const Key('qr-import-button')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<SlidingSegments<String>>(find.byType(SlidingSegments<String>))
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('import-submit')))
          .onPressed,
      isNull,
    );
    expect(reads, 1);
    await tester.tap(find.byKey(const Key('qr-import-button')));
    await tester.pump();
    // The closing popup route can retain its items during this pending read.
    // The disabled control must not start another picker operation.
    expect(reads, 1);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const Key('qr-import-button')),
          )
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('import-submit')))
          .onPressed,
      isNull,
      reason: 'QR mode still requires decoded data before confirmation',
    );
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR mode keeps name above tabs and native camera disabled', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    var reads = 0;
    await _open(tester, controller, () async {
      reads++;
      return _profile;
    });
    await tester.enterText(find.byKey(const Key('subscription-name')), 'My QR');
    await tester.tap(find.text('QR'));
    await tester.pumpAndSettle();
    final tabs = find.byType(SlidingSegments<String>);
    expect(
      tester
          .widget<SlidingSegments<String>>(tabs)
          .items
          .map((item) => item.value),
      ['link', 'text', 'qr'],
    );
    expect(
      tester.getBottomLeft(find.byKey(const Key('subscription-name'))).dy,
      lessThan(tester.getTopLeft(tabs).dy),
    );
    expect(find.byKey(const Key('subscription-input')), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('qr-camera-button')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('qr-camera-button')));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(controller.groups, isEmpty);
    await _textMode(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('subscription-name')))
          .controller!
          .text,
      'My QR',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('clipboard QR uses the menu and still requires confirmation', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    var reads = 0;
    await _open(tester, controller, () async {
      reads++;
      return _profile;
    });
    await _openQrMenu(tester);
    expect(reads, 0);
    expect(find.text('Выбрать файл'), findsOneWidget);
    expect(find.text('Из буфера обмена'), findsOneWidget);
    await tester.tap(find.text('Из буфера обмена'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(_input(tester), _profile);
    expect(controller.groups, isEmpty);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image permission failure does not leak errors or erase input', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await _open(tester, controller, () async {
      throw PlatformException(
        code: 'permission_denied',
        message: 'PRIVATE-PERMISSION-DETAIL',
      );
    });
    await _textMode(tester);
    await tester.enterText(
      find.byKey(const Key('subscription-input')),
      _profile,
    );
    await _read(tester);
    expect(find.text('Не удалось открыть изображение.'), findsOneWidget);
    expect(find.textContaining('PRIVATE-PERMISSION-DETAIL'), findsNothing);
    await _textMode(tester);
    expect(_input(tester), _profile);
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
