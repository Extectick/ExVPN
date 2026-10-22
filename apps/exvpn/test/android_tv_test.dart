// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn/src/adaptive_sheet.dart';
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/import_dialog.dart';
import 'package:exvpn/src/power_button.dart';
import 'package:exvpn/src/sliding_segments.dart';
import 'package:exvpn/src/theme.dart';
import 'package:exvpn/src/tv_presentation.dart';
import 'package:exvpn/services/device_presentation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget child, {bool tv = true}) => MaterialApp(
  theme: exVpnTheme(Brightness.dark),
  builder: (context, child) => TvAppPresentation(enabled: tv, child: child!),
  home: Scaffold(body: child),
);

void focusInk(WidgetTester tester, Finder parent) {
  final ink = tester.widget<InkWell>(
    find.descendant(of: parent, matching: find.byType(InkWell)).first,
  );
  ink.focusNode!.requestFocus();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('cold Android presentation detection', () {
    const channel = MethodChannel('exvpn/presentation');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test(
      'recovers a slow native reply instead of locking TV to portrait',
      () async {
        final delayed = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return calls == 1 ? delayed.future : true;
        });
        try {
          expect(
            await isAndroidTelevision(
              requestTimeout: const Duration(milliseconds: 10),
            ),
            isTrue,
          );
        } finally {
          delayed.complete(true);
        }
        expect(calls, 2);
      },
    );

    test(
      'recovers a channel which is not registered on the first native frame',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (++calls == 1) throw MissingPluginException();
          return true;
        });
        expect(await isAndroidTelevision(), isTrue);
      },
    );

    test(
      'explicit phone reply is immediate and unavailable channel is bounded',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return false;
        });
        expect(await isAndroidTelevision(), isFalse);
        expect(calls, 1);
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          throw MissingPluginException();
        });
        expect(await isAndroidTelevision(), isFalse);
        expect(calls, 4);
      },
    );
  });

  testWidgets('TV is explicit, not inferred from a wide tablet viewport', (
    tester,
  ) async {
    final controller = AppController.demo();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final home = HomeScreen(
      controller: controller,
      themeMode: ThemeMode.dark,
      onThemeChanged: (_) {},
    );
    await tester.pumpWidget(app(home, tv: false));
    expect(find.byKey(const Key('android-tv-home')), findsNothing);
    await tester.pumpWidget(app(home));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-tv-home')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'VPN connection');
    for (final size in const [
      Size(1280, 720),
      Size(1920, 1080),
      Size(3840, 2160),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('remote OK activates once, long press never toggles twice', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      app(
        Center(
          child: PowerButton(
            size: 218,
            autofocus: true,
            onPressed: () => activations++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(activations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activations, 2);
  });

  testWidgets('arrows leave the power disk and OK selects a server', (
    tester,
  ) async {
    final controller = AppController.demo();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        HomeScreen(
          controller: controller,
          themeMode: ThemeMode.dark,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('VPN connection'),
    );
    TvInkWell? row;
    for (var step = 0; step < 12; step++) {
      row = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TvInkWell>();
      if ((row?.key as ValueKey?)?.value.toString().startsWith('server-') ==
          true) {
        break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect((row?.key as ValueKey?)?.value.toString(), startsWith('server-'));
    final before = controller.selectedServerId;
    // The next row remains reachable while the list owns focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(controller.selectedServerId, isNotNull);
    expect(controller.selectedServerId, isNot(before));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('directional focus scrolls long lists without touch', (
    tester,
  ) async {
    var selected = -1;
    await tester.pumpWidget(
      app(
        SizedBox(
          height: 300,
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 30; i++)
                  TvInkWell(
                    key: ValueKey('row-$i'),
                    autofocus: i == 0,
                    onTap: () => selected = i,
                    child: SizedBox(
                      height: 58,
                      width: 400,
                      child: Text('Server $i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 28; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, 28);
    expect(
      tester.getRect(find.byKey(const ValueKey('row-28'))).bottom,
      lessThanOrEqualTo(301),
    );
  });

  testWidgets('TV segments move focus without committing a different policy', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => Center(
            child: SlidingSegments<int>(
              items: const [
                SlidingSegment(value: 0, label: 'Off'),
                SlidingSegment(value: 1, label: 'Only these'),
              ],
              value: selected,
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      ),
    );
    final first = find.byType(TvInkWell).first;
    focusInk(tester, first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(selected, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('Up and Down leave text inputs; OK reopens the keyboard', (
    tester,
  ) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            TextField(focusNode: first),
            TextField(focusNode: second),
          ],
        ),
      ),
    );
    first.requestFocus();
    await tester.pumpAndSettle();
    tester.testTextInput.hide();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(second.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(first.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'TV sheet is centered and remote Back restores its launcher focus',
    (tester) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Center(
              child: TvInkWell(
                key: const Key('open-sheet'),
                autofocus: true,
                onTap: () => showAppSheet<void>(
                  context: context,
                  builder: (context) => SizedBox(
                    width: 440,
                    height: 250,
                    child: TextButton(
                      autofocus: true,
                      onPressed: () {},
                      child: const Text('Settings'),
                    ),
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-centered-sheet')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-centered-sheet')), findsNothing);
      final focus = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TvInkWell>();
      expect(focus?.key, const Key('open-sheet'));
    },
  );

  testWidgets('TV import starts on Close without opening the keyboard', (
    tester,
  ) async {
    final controller = AppController.demo();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(ImportDialog(controller: controller)));
    await tester.pumpAndSettle();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<IconButton>();
    expect(button?.tooltip, 'Close');
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'Android presentation channel accepts only an explicit TV hint',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('exvpn/presentation');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'isTelevision');
        expect(call.arguments, isNull);
        return true;
      });
      expect(await isAndroidTelevision(), isTrue);
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await isAndroidTelevision(), isFalse);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await isAndroidTelevision(), isFalse);
    },
  );
}
