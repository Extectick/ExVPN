import 'dart:async';

import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn/services/subscription_loader.dart';
import 'package:exvpn/src/subscription_issues_dialog.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const oldProfile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Old';
const newProfile =
    'vless://00000000-0000-4000-8000-000000000002@sample.invalid:443?security=tls#PRIVATE-NAME';
const broken = 'unknown://PRIVATE-CREDENTIAL@sample.invalid/PRIVATE-TOKEN';

void main() {
  late AppController app;
  late String id;
  setUp(() {
    app = AppController();
    id = app.addSubscription(name: 'PRIVATE-GROUP', raw: oldProfile).groupId;
  });
  tearDown(() => app.dispose());

  Future<void> open(
    WidgetTester tester, {
    ValueChanged<SubscriptionReviewOutcome>? completed,
    double textScale = 1,
    Size size = const Size(426, 922),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final outcome = await showSubscriptionIssues(
                  context,
                  controller: app,
                  groupId: id,
                );
                completed?.call(outcome);
              },
              child: const Text('Review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
  }

  test('all reasons use fixed text and document/one-based record labels', () {
    for (final code in ImportIssueCode.values) {
      expect(
        importIssueMessage(ImportIssue(0, code)),
        startsWith('Подписка: '),
      );
      expect(
        importIssueMessage(ImportIssue(7, code)),
        startsWith('Запись 7: '),
      );
    }
    expect(
      importIssueMessage(
        const ImportIssue(1, ImportIssueCode.ignoredLocalConfiguration),
      ),
      contains('используются настройки ExVPN'),
    );
  });

  testWidgets(
    'default cancellation preserves data and hides all provider secrets',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
      SubscriptionReviewOutcome? outcome;
      await open(tester, completed: (value) => outcome = value);
      expect(find.textContaining('Запись 2: Протокол'), findsOneWidget);
      expect(find.textContaining('PRIVATE-'), findsNothing);
      expect(find.textContaining('sample.invalid'), findsNothing);
      expect(app.selectedServer!.name, 'Old');
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(outcome, SubscriptionReviewOutcome.keptCurrent);
      expect(app.selectedServer!.name, 'Old');
    },
  );

  testWidgets('explicit confirmation applies only the displayed candidate', (
    tester,
  ) async {
    app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    SubscriptionReviewOutcome? outcome;
    await open(tester, completed: (value) => outcome = value);
    await tester.tap(find.byKey(const Key('accept-partial-subscription')));
    await tester.pumpAndSettle();
    expect(outcome, SubscriptionReviewOutcome.applied);
    expect(app.selectedServer!.name, 'PRIVATE-NAME');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a response arriving while the dialog is open invalidates confirmation',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
      SubscriptionReviewOutcome? outcome;
      await open(tester, completed: (value) => outcome = value);
      app.updateSubscription(groupId: id, raw: oldProfile);
      await tester.tap(find.byKey(const Key('accept-partial-subscription')));
      await tester.pumpAndSettle();
      expect(outcome, SubscriptionReviewOutcome.stale);
      expect(app.selectedServer!.name, 'Old');
    },
  );

  testWidgets(
    'invalid document has reasons but no empty-list acceptance action',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '');
      await open(tester);
      expect(find.text('Подписка: Список подключений пуст.'), findsOneWidget);
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long issue list scrolls and actions remain usable at narrow width',
    (tester) async {
      app.updateSubscription(
        groupId: id,
        raw: [newProfile, ...List.filled(40, broken)].join('\n'),
      );
      await open(tester, size: const Size(344, 740), textScale: 1.4);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.textContaining('Запись 41:'),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('subscription-issues-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.textContaining('Запись 41:'), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'Old');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual text replacement offers confirmation and preserves input on cancel',
    (tester) async {
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
                      ImportDialog(controller: app, group: app.groups.single),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Текст'));
      await tester.enterText(
        find.byKey(const Key('subscription-input')),
        '$newProfile\n$broken',
      );
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Обновить часть подписки?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'Old');
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(
        find.text(
          'Частичное обновление не применено. Рабочий список сохранён.',
        ),
        findsOneWidget,
      );
      expect(app.pendingUpdate(id), isNotNull);
      await tester.tap(find.text('Ссылка'));
      await tester.enterText(
        find.byKey(const Key('subscription-input')),
        'http://example.invalid/new',
      );
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      expect(app.pendingUpdate(id), isNull);
      expect(app.selectedServer!.name, 'Old');
      expect(
        find.textContaining('Нужна корректная ссылка HTTPS'),
        findsOneWidget,
      );
      await tester.tap(find.text('Текст'));
      await tester.enterText(
        find.byKey(const Key('subscription-input')),
        '$newProfile\n$broken',
      );
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('accept-partial-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'PRIVATE-NAME');
      expect(find.byType(ImportDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late manual download cannot replace newly accepted content', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final loader = SubscriptionLoader(
      client: MockClient((_) => response.future),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ImportDialog(
                  controller: app,
                  group: app.groups.single,
                  loader: loader,
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
    await tester.enterText(
      find.byKey(const Key('subscription-input')),
      'https://example.invalid/sub',
    );
    await tester.tap(find.byKey(const Key('import-submit')));
    await tester.pump();
    app.updateSubscription(groupId: id, raw: newProfile);
    response.complete(http.Response(oldProfile, 200));
    await tester.pumpAndSettle();
    expect(app.selectedServer!.name, 'PRIVATE-NAME');
    expect(
      find.text('Подписка изменилась. Повторите обновление.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
