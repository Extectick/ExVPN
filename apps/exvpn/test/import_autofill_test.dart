import 'dart:async';

import 'package:exvpn/services/subscription_loader.dart';
import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _url = 'https://example.invalid/subscription';
const _profile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample';
const _document = SubscriptionDocument(
  body: _profile,
  providerName: 'Provider name',
);
final _name = find.byKey(const Key('subscription-name'));
final _input = find.byKey(const Key('subscription-input'));

String _value(WidgetTester tester, Finder finder) =>
    tester.widget<TextField>(finder).controller!.text;

Future<void> _open(
  WidgetTester tester,
  AppController controller,
  Future<SubscriptionDocument> Function(String) load,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  ImportDialog(controller: controller, documentLoader: load),
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
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async =>
              call.method == 'Clipboard.getData' ? {'text': clipboard} : null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  testWidgets(
    'clipboard HTTPS loads provider name and keeps automatic naming after import',
    (tester) async {
      final app = AppController();
      addTearDown(app.dispose);
      clipboard = _url;
      var calls = 0;
      await _open(tester, app, (source) async {
        expect(source, _url);
        calls++;
        return _document;
      });
      expect(_value(tester, _input), _url);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(_value(tester, _name), 'Provider name');
      final field = tester.widget<TextField>(_input).controller!;
      field.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      expect(app.groups.single.name, 'Provider name');
      expect(app.groups.single.nameIsAutomatic, isTrue);
      expect(calls, 1);
    },
  );

  testWidgets('non URL clipboard does not fill or fetch a subscription', (
    tester,
  ) async {
    final app = AppController();
    addTearDown(app.dispose);
    clipboard = 'unrelated clipboard text';
    await _open(tester, app, (_) async {
      fail('Unexpected network lookup');
    });
    expect(_value(tester, _input), isEmpty);
    expect(_value(tester, _name), isEmpty);
  });

  testWidgets(
    'late provider metadata cannot replace a manual name or a newer source',
    (tester) async {
      final app = AppController();
      addTearDown(app.dispose);
      final old = Completer<SubscriptionDocument>();
      final current = Completer<SubscriptionDocument>();
      await _open(
        tester,
        app,
        (source) => source.endsWith('/old') ? old.future : current.future,
      );
      await tester.enterText(_input, 'https://example.invalid/old');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(_input, 'https://example.invalid/current');
      await tester.pump(const Duration(milliseconds: 600));
      current.complete(_document);
      await tester.pumpAndSettle();
      expect(_value(tester, _name), 'Provider name');
      await tester.enterText(_name, 'My name');
      old.complete(
        const SubscriptionDocument(
          body: _profile,
          providerName: 'Old provider',
        ),
      );
      await tester.pumpAndSettle();
      expect(_value(tester, _name), 'My name');
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      expect(app.groups.single.name, 'My name');
      expect(app.groups.single.nameIsAutomatic, isFalse);
      expect(app.groups.single.sourceUrl, 'https://example.invalid/current');
    },
  );
}
