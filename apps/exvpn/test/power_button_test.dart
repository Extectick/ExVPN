import 'dart:ui' as ui;

import 'package:exvpn/src/power_button.dart';
import 'package:exvpn/src/theme.dart';
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
  bool active = false,
  ValueNotifier<bool>? activeState,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  Widget button(bool confirmedActive) => PowerButton(
    key: _buttonKey,
    size: 200,
    active: confirmedActive,
    onPressed: callback,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: exVpnTheme(Brightness.dark),
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
                child: activeState == null
                    ? button(active)
                    : ValueListenableBuilder<bool>(
                        valueListenable: activeState,
                        builder: (_, value, _) => button(value),
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
) async => [
  for (final color in await _colors(tester, coordinates))
    (color.toARGB32() >> 16) & 0xff,
];

Future<List<Color>> _colors(
  WidgetTester tester,
  List<(int, int)> coordinates,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_surfaceKey),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  // Read rendered pixels, including the transparent artwork margin and effects
  // outside the circular target, without relying on particular widget layers.
  return [
    for (final (x, y) in coordinates)
      Color.fromARGB(
        bytes!.getUint8((y * 320 + x) * 4 + 3),
        bytes.getUint8((y * 320 + x) * 4),
        bytes.getUint8((y * 320 + x) * 4 + 1),
        bytes.getUint8((y * 320 + x) * 4 + 2),
      ),
  ];
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

  testWidgets('active glow remains visible on all four edges during hover', (
    tester,
  ) async {
    await _open(tester, () {});
    final idle = await _edgePixels(tester);
    await _open(tester, () {}, active: true);
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
        greaterThan(idle[i] + 15),
        reason: 'Active glow clipped on edge $i during hover',
      );
    }
    expect(tester.takeException(), isNull);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(await _edgePixels(tester), before);
  });

  testWidgets('inactive hover preserves the Space Gray disc without a glow', (
    tester,
  ) async {
    var calls = 0;
    await _open(tester, () => calls++);
    const samples = [(56, 160), (263, 160), (160, 56), (160, 263), (100, 160)];
    final before = await _colors(tester, samples);
    final target = tester.getRect(find.byKey(_buttonKey));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(target.center);
    await tester.pumpAndSettle();
    final hovered = await _colors(tester, samples);
    expect(hovered, before);
    for (var i = 0; i < 4; i++) {
      expect(
        hovered[i],
        const Color(0xff071018),
        reason: 'Idle glow on edge $i',
      );
    }
    final disc = hovered.last;
    expect(disc.r, inInclusiveRange(.06, .4));
    expect((disc.r - disc.g).abs(), lessThan(.08));
    expect((disc.r - disc.b).abs(), lessThan(.08));
    expect(tester.getRect(find.byKey(_buttonKey)), target);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
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
    'confirmed activation blooms outside all edges and fades without delaying callback',
    (tester) async {
      var calls = 0;
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await _open(tester, () => calls++, activeState: active);
      const samplePoints = [(46, 160), (273, 160), (160, 46), (160, 273)];
      final before = await _pixels(tester, samplePoints);
      await tester.tap(find.byKey(_buttonKey));
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 190));
      expect(await _pixels(tester, samplePoints), before);
      active.value = true;
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
      active.value = false;
      await tester.pumpAndSettle();
      expect(await _pixels(tester, samplePoints), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing during a wave cancels feedback and does not repeat activation',
    (tester) async {
      var calls = 0;
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await _open(tester, () => calls++, activeState: active);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      active.value = true;
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
    final active = ValueNotifier(false);
    addTearDown(active.dispose);
    await _open(tester, () => calls++, reduceMotion: true, activeState: active);
    const samplePoints = [(46, 160), (273, 160), (160, 46), (160, 273)];
    await tester.tap(find.byKey(_buttonKey));
    expect(calls, 1);
    active.value = true;
    await tester.pump();
    final first = await _pixels(tester, samplePoints);
    await tester.pump(const Duration(milliseconds: 190));
    expect(await _pixels(tester, samplePoints), first);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
