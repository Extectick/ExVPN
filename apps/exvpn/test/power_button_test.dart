import 'dart:ui' as ui;

import 'package:exvpn/src/power_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _buttonKey = Key('test-power');
const _surfaceKey = Key('test-surface');

Future<void> _open(
  WidgetTester tester,
  VoidCallback callback, {
  bool reduceMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Center(
        child: RepaintBoundary(
          key: _surfaceKey,
          child: SizedBox.square(
            dimension: 320,
            child: ColoredBox(
              color: const Color(0xff071018),
              child: Center(
                child: PowerButton(
                  key: _buttonKey,
                  size: 200,
                  onPressed: callback,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<List<int>> _edgePixels(WidgetTester tester) =>
    _pixels(tester, [(56, 160), (263, 160), (160, 56), (160, 263)]);

Future<List<int>> _pixels(
  WidgetTester tester,
  List<(int, int)> coordinates,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_surfaceKey),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  // All four points lie outside the 200 px hit target in the 320 px surface.
  // Check rendered pixels rather than the presence of particular widgets.
  return [for (final (x, y) in coordinates) bytes!.getUint8((y * 320 + x) * 4)];
}))!;

void main() {
  testWidgets('touch releases once and cancelled gestures never activate', (
    tester,
  ) async {
    var calls = 0;
    await _open(tester, () => calls++);
    final button = find.byKey(_buttonKey);
    final target = tester.getRect(button);
    final gesture = await tester.startGesture(target.center);
    await tester.pump(const Duration(milliseconds: 160));
    expect(calls, 0);
    expect(tester.getRect(button), target);
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 1);

    final cancelled = await tester.startGesture(target.center);
    await tester.pump(const Duration(milliseconds: 160));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.getRect(button), target);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard tab focus supports Enter and Space without key repeats',
    (tester) async {
      var calls = 0;
      await _open(tester, () => calls++);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hover outline paints around all four edges without cropping', (
    tester,
  ) async {
    await _open(tester, () {});
    final before = await _edgePixels(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(_buttonKey)));
    await tester.pumpAndSettle();
    final hovered = await _edgePixels(tester);
    for (var i = 0; i < 4; i++) {
      expect(
        hovered[i],
        greaterThan(before[i] + 15),
        reason: 'Edge $i clipped',
      );
    }
    expect(tester.takeException(), isNull);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(await _edgePixels(tester), before);
  });

  testWidgets('keyboard focus outline stays visible outside the hit target', (
    tester,
  ) async {
    await _open(tester, () {});
    final before = await _edgePixels(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focused = await _edgePixels(tester);
    for (var i = 0; i < 4; i++) {
      expect(
        focused[i],
        greaterThan(before[i] + 15),
        reason: 'Edge $i clipped',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'activation blooms beyond the disc and then fades without delaying callback',
    (tester) async {
      var calls = 0;
      await _open(tester, () => calls++);
      const samplePoints = [(46, 160), (273, 160), (160, 46), (160, 273)];
      final before = await _pixels(tester, samplePoints);
      await tester.tap(find.byKey(_buttonKey));
      expect(calls, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 190));
      final bloom = await _pixels(tester, samplePoints);
      for (var i = 0; i < 4; i++) {
        expect(
          bloom[i],
          greaterThan(before[i] + 15),
          reason: 'Wave clipped on edge $i',
        );
      }
      await tester.pumpAndSettle();
      final after = await _pixels(tester, samplePoints);
      for (var i = 0; i < 4; i++) {
        expect(
          after[i],
          lessThan(bloom[i] - 10),
          reason: 'Wave did not fade on edge $i',
        );
      }
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing during a wave cancels feedback and does not repeat activation',
    (tester) async {
      var calls = 0;
      await _open(tester, () => calls++);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion activates immediately with no expanding wave', (
    tester,
  ) async {
    var calls = 0;
    await _open(tester, () => calls++, reduceMotion: true);
    const samplePoints = [(46, 160), (273, 160), (160, 46), (160, 273)];
    await tester.tap(find.byKey(_buttonKey));
    expect(calls, 1);
    await tester.pump();
    final first = await _pixels(tester, samplePoints);
    await tester.pump(const Duration(milliseconds: 190));
    expect(await _pixels(tester, samplePoints), first);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
