// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn/src/home_screen.dart';
import 'package:exvpn/src/mobile_presentation.dart';
import 'package:exvpn/src/theme.dart';
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('display classification survives rotation and honors density', () {
    expect(mobileFormFactor(const Size(1080, 2400), 3), MobileFormFactor.phone);
    expect(mobileFormFactor(const Size(2400, 1080), 3), MobileFormFactor.phone);
    expect(
      mobileFormFactor(const Size(1200, 1920), 2),
      MobileFormFactor.tablet,
    );
    expect(
      mobileFormFactor(const Size(1920, 1200), 2),
      MobileFormFactor.tablet,
    );
    expect(mobileFormFactor(const Size(1198, 1920), 2), MobileFormFactor.phone);
  });

  Future<List<Object?>> open(
    WidgetTester tester,
    Size size, {
    bool tv = false,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.display.size = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final orientations = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final controller = AppController.demo();
    controller.toggleGroup('demo-backup');
    for (var i = 0; i < 10; i++) {
      controller.addSubscription(
        name: 'Sample $i',
        raw: 'vless://00000000-0000-4000-8000-000000000001@sample.invalid:443?security=tls#Sample',
      );
    }
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: exVpnTheme(Brightness.light),
        builder: (context, child) =>
            AndroidMobilePresentation(television: tv, child: child!),
        home: HomeScreen(
          controller: controller,
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return orientations;
  }

  testWidgets('phone list scroll leaves power, heading and toolbar fixed', (
    tester,
  ) async {
    final orientations = await open(tester, const Size(393, 852));
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    expect(find.byKey(const Key('phone-home')), findsOneWidget);
    final power = find.byKey(const Key('connect-button'));
    final settings = find.byKey(const Key('settings-button'));
    final add = find.byKey(const Key('add-button'));
    final before = [
      tester.getRect(power),
      tester.getRect(settings),
      tester.getRect(add),
    ];
    final scroll = find.descendant(
      of: find.byKey(const Key('phone-server-panel')),
      matching: find.byType(SingleChildScrollView),
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    await tester.drag(scroll, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect([
      tester.getRect(power),
      tester.getRect(settings),
      tester.getRect(add),
    ], before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(600, 960), const Size(1024, 768)]) {
    testWidgets('tablet $size uses split layout and allows OS rotation', (
      tester,
    ) async {
      final orientations = await open(tester, size);
      expect(orientations.last, isEmpty);
      expect(find.byKey(const Key('tablet-home')), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(const Key('connect-button'))).dx,
        lessThan(tester.getCenter(find.byKey(const Key('add-button'))).dx),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('compact phone supports larger text without overflow', (
    tester,
  ) async {
    await open(tester, const Size(320, 568), scale: 1.5);
    expect(find.byKey(const Key('phone-home')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('display change releases portrait lock, TV never locks', (
    tester,
  ) async {
    final orientations = await open(tester, const Size(393, 852));
    tester.view.display.size = const Size(1024, 768);
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();
    expect(orientations.last, isEmpty);
    expect(find.byKey(const Key('tablet-home')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    final tvOrientations = await open(tester, const Size(393, 852), tv: true);
    expect(tvOrientations.last, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
