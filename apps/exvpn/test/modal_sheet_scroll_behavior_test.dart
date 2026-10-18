import 'package:exvpn/src/modal_sheet_scroll_behavior.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _listKey = Key('sheet-list');
const _scopeKey = Key('sheet-scope');

class _Observer extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

Future<({ScrollController controller, _Observer observer})> _open(
  WidgetTester tester, {
  int count = 3,
  bool enableDrag = true,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = ScrollController();
  addTearDown(controller.dispose);
  final observer = _Observer();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android, useMaterial3: true),
      navigatorObservers: [observer],
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              enableDrag: enableDrag,
              builder: (_) => ModalSheetScrollScope(
                key: _scopeKey,
                child: SizedBox(
                  height: 420,
                  child: ListView.builder(
                    key: _listKey,
                    controller: controller,
                    itemCount: count,
                    itemExtent: 56,
                    itemBuilder: (_, index) =>
                        ListTile(title: Text('Item $index')),
                  ),
                ),
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
  return (controller: controller, observer: observer);
}

Future<void> _slowPull(
  WidgetTester tester,
  double distance, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final start = tester.getTopLeft(find.byKey(_listKey)) + const Offset(120, 34);
  final gesture = await tester.startGesture(start, kind: kind);
  for (var i = 0; i < 10; i++) {
    await gesture.moveBy(Offset(0, distance / 10));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 150));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final kind in [
    PointerDeviceKind.unknown,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  ]) {
    testWidgets(
      '${kind.name} direct-contact pointer hands content drag to the sheet',
      (tester) async {
        final state = await _open(tester, count: 40);
        await _slowPull(tester, 300, kind: kind);
        expect(find.byKey(_scopeKey), findsNothing);
        expect(state.observer.pops, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final count in [3, 40]) {
    testWidgets(
      'downward content pull dismisses ${count == 3 ? 'short' : 'long'} list at top exactly once',
      (tester) async {
        final state = await _open(tester, count: count);
        await _slowPull(tester, 300);
        expect(find.byKey(_scopeKey), findsNothing);
        expect(state.observer.pops, 1);
        expect(find.text('Open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a list away from its top scrolls before moving the sheet', (
    tester,
  ) async {
    final state = await _open(tester, count: 40);
    state.controller.jumpTo(400);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(_scopeKey));
    await _slowPull(tester, 120);
    expect(state.controller.offset, greaterThan(0));
    expect(state.controller.offset, lessThan(400));
    expect(tester.getTopLeft(find.byKey(_scopeKey)), before);
    expect(state.observer.pops, 0);
  });

  testWidgets('a short slow pull returns without popping', (tester) async {
    final state = await _open(tester, count: 40);
    final sheetHeight = tester.getSize(find.byType(BottomSheet)).height;
    expect(65 / sheetHeight, lessThan(0.2));
    final before = tester.getTopLeft(find.byKey(_scopeKey));
    await _slowPull(tester, 65);
    expect(tester.getTopLeft(find.byKey(_scopeKey)), before);
    expect(state.observer.pops, 0);
    expect(state.controller.offset, 0);
  });

  testWidgets(
    'a slow central pull of 35 percent closes without reaching half-height',
    (tester) async {
      final state = await _open(tester, count: 40);
      final sheetHeight = tester.getSize(find.byType(BottomSheet)).height;
      final pull = sheetHeight * 0.35;
      // Include gesture recognition slop, while keeping the entire finger path
      // below half the sheet height and within the screen from its centre.
      const recognitionSlop = 24.0;
      expect(pull + recognitionSlop, lessThan(sheetHeight * 0.5));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_listKey)),
      );
      await gesture.moveBy(const Offset(0, recognitionSlop));
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, pull / 10));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.observer.pops, 0);
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(_scopeKey), findsNothing);
      expect(state.observer.pops, 1);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('upward scroll and wheel overscroll do not dismiss', (
    tester,
  ) async {
    final state = await _open(tester, count: 40);
    await tester.drag(find.byKey(_listKey), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(state.controller.offset, greaterThan(0));
    state.controller.jumpTo(0);
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(_listKey)),
        scrollDelta: const Offset(0, -1000),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_scopeKey), findsOneWidget);
    expect(state.observer.pops, 0);
  });

  testWidgets('indirect trackpad overscroll does not dismiss', (tester) async {
    final state = await _open(tester, count: 40);
    await _slowPull(tester, 300, kind: PointerDeviceKind.trackpad);
    expect(find.byKey(_scopeKey), findsOneWidget);
    expect(state.observer.pops, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled content drag remains disabled', (tester) async {
    final state = await _open(tester, enableDrag: false);
    await _slowPull(tester, 300);
    expect(find.byKey(_scopeKey), findsOneWidget);
    expect(state.observer.pops, 0);
  });

  testWidgets(
    'sheet follows a touch pull before release and cancelled pull returns',
    (tester) async {
      final state = await _open(tester, count: 40);
      final before = tester.getTopLeft(find.byKey(_scopeKey));
      final start =
          tester.getTopLeft(find.byKey(_listKey)) + const Offset(120, 34);
      final gesture = await tester.startGesture(start);
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 38));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        tester.getTopLeft(find.byKey(_scopeKey)).dy,
        greaterThan(before.dy + 200),
      );
      expect(state.observer.pops, 0);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.byKey(_scopeKey), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(_scopeKey)), before);
      expect(state.observer.pops, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fast downward content fling dismisses without a half-height pull',
    (tester) async {
      final state = await _open(tester, count: 40);
      final start =
          tester.getTopLeft(find.byKey(_listKey)) + const Offset(120, 34);
      await tester.flingFrom(start, const Offset(0, 110), 1200);
      await tester.pumpAndSettle();
      expect(find.byKey(_scopeKey), findsNothing);
      expect(state.observer.pops, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
