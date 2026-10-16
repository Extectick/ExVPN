import 'dart:async';

import 'package:exvpn/services/qr_import.dart';
import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443'
    '?security=tls#QR%20Sample';

Future<void> _open(
  WidgetTester tester,
  AppController controller,
  Future<String?> Function() reader,
) async {
  tester.view.physicalSize = const Size(426, 922);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  ImportDialog(controller: controller, qrReader: reader),
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

Future<void> _read(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('qr-import-button')));
  await tester.pumpAndSettle();
}

String _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('subscription-input')))
    .controller!
    .text;

void main() {
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
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {false},
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pumpAndSettle();
    expect(controller.groups, hasLength(1));
    expect(controller.groups.single.servers.single.name, 'QR Sample');
    expect(find.byType(ImportDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTTPS QR fills link mode without fetching or importing', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    const url = 'https://example.invalid/sub/synthetic-test';
    await _open(tester, controller, () async => url);
    await _read(tester);
    expect(_input(tester), url);
    expect(controller.groups, isEmpty);
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {true},
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });

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
    await tester.enterText(
      find.byKey(const Key('subscription-input')),
      _profile,
    );
    await _read(tester);
    expect(_input(tester), _profile);
    await _read(tester);
    expect(_input(tester), _profile);
    expect(
      find.text('QR-код не найден. Выберите чёткое изображение с одним кодом.'),
      findsOneWidget,
    );
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
    await tester.tap(find.byKey(const Key('qr-import-button')));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('qr-import-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('import-submit')))
          .onPressed,
      isNull,
    );
    expect(reads, 1);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('qr-import-button')))
          .onPressed,
      isNotNull,
    );
    expect(controller.groups, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
