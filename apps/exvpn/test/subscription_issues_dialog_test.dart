import 'dart:async';

import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn/services/subscription_loader.dart';
import 'package:exvpn/src/subscription_issues_dialog.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const oldProfile =
    'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Old';
const newProfile =
    'vless://00000000-0000-4000-8000-000000000002@sample.invalid:443?security=tls#PRIVATE-NAME';
const cleanNewProfile =
    'vless://00000000-0000-4000-8000-000000000002@sample.invalid:443?security=tls#New';
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
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
    'brief issue disclosure preserves data and hides raw provider secrets',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
      SubscriptionReviewOutcome? outcome;
      await open(tester, completed: (value) => outcome = value);
      expect(find.text('PRIVATE-GROUP'), findsOneWidget);
      expect(
        find.textContaining('Часть подключений пока не поддерживается.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Последний рабочий список сохранён.'),
        findsOneWidget,
      );
      expect(find.textContaining('Запись 2:'), findsNothing);
      for (final secret in [
        'PRIVATE-NAME',
        'PRIVATE-CREDENTIAL',
        'PRIVATE-TOKEN',
      ]) {
        expect(find.textContaining(secret), findsNothing);
      }
      expect(find.textContaining('sample.invalid'), findsNothing);
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      expect(find.byTooltip('Закрыть').hitTestable(), findsOneWidget);
      expect(app.selectedServer!.name, 'Old');
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(outcome, SubscriptionReviewOutcome.keptCurrent);
      expect(app.selectedServer!.name, 'Old');
    },
  );

  testWidgets(
    'read-only issue dialog cannot silently accept a partial candidate',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
      SubscriptionReviewOutcome? outcome;
      await open(tester, completed: (value) => outcome = value);
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      final candidate = app.pendingUpdate(id);
      expect(candidate, isNotNull);
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(outcome, SubscriptionReviewOutcome.keptCurrent);
      expect(app.pendingUpdate(id), same(candidate));
      expect(app.selectedServer!.name, 'Old');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing disclosure cannot undo newer accepted content', (
    tester,
  ) async {
    app.updateSubscription(groupId: id, raw: '$newProfile\n$broken');
    SubscriptionReviewOutcome? outcome;
    await open(tester, completed: (value) => outcome = value);
    app.updateSubscription(groupId: id, raw: cleanNewProfile);
    expect(app.pendingUpdate(id), isNull);
    await tester.tap(find.byKey(const Key('keep-subscription')));
    await tester.pumpAndSettle();
    expect(outcome, SubscriptionReviewOutcome.keptCurrent);
    expect(app.selectedServer!.name, 'New');
  });

  testWidgets(
    'invalid document has reasons but no empty-list acceptance action',
    (tester) async {
      app.updateSubscription(groupId: id, raw: '');
      await open(tester);
      expect(
        find.textContaining('В подписке нет доступных подключений.'),
        findsOneWidget,
      );
      expect(find.textContaining('Рабочий список не изменён.'), findsOneWidget);
      expect(app.selectedServer!.name, 'Old');
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'many issues use a bounded summary with an accessible close action',
    (tester) async {
      app.updateSubscription(
        groupId: id,
        raw: [newProfile, ...List.filled(40, broken)].join('\n'),
      );
      await open(tester, size: const Size(344, 740), textScale: 1.4);
      expect(tester.takeException(), isNull);
      expect(app.groups.single.issues.length, 40);
      expect(
        find.textContaining('Часть подключений пока не поддерживается.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('subscription-issues-list')), findsNothing);
      expect(find.textContaining('Запись '), findsNothing);
      expect(find.byTooltip('Закрыть').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      expect(find.textContaining('PRIVATE-CREDENTIAL'), findsNothing);
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'Old');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual partial replacement keeps input and working data until a clean replacement',
    (tester) async {
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
      expect(
        find.descendant(
          of: find.byKey(const Key('subscription-issues-dialog')),
          matching: find.text('PRIVATE-GROUP'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Часть подключений пока не поддерживается.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'Old');
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('subscription-input')))
            .controller!
            .text,
        '$newProfile\n$broken',
      );
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
      expect(
        find.byKey(const Key('accept-partial-subscription')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('keep-subscription')));
      await tester.pumpAndSettle();
      expect(app.selectedServer!.name, 'Old');
      await tester.enterText(
        find.byKey(const Key('subscription-input')),
        cleanNewProfile,
      );
      await tester.tap(find.byKey(const Key('import-submit')));
      await tester.pumpAndSettle();
      expect(app.pendingUpdate(id), isNull);
      expect(app.selectedServer!.name, 'New');
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
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
    app.updateSubscription(groupId: id, raw: cleanNewProfile);
    response.complete(http.Response(oldProfile, 200));
    await tester.pumpAndSettle();
    expect(app.selectedServer!.name, 'New');
    expect(
      find.text('Подписка изменилась. Повторите обновление.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
