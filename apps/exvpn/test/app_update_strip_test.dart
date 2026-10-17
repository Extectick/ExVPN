import 'package:exvpn/src/app_update_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'actual byte progress and SDK indeterminate progress share fixed height',
    (tester) async {
      var taps = 0;
      Future<void> show(AppUpdatePresentation state) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: AppUpdateStrip(state: state, onPressed: () => taps++),
              ),
            ),
          ),
        ),
      );
      await show(const AppUpdatePresentation());
      expect(tester.getSize(find.byType(AppUpdateStrip)).height, 24);
      await tester.tap(find.byType(AppUpdateStrip));
      expect(taps, 1);
      await show(
        const AppUpdatePresentation(
          phase: AppUpdatePhase.downloading,
          progress: .42,
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .42,
      );
      await tester.tap(find.byType(AppUpdateStrip));
      expect(taps, 1);
      await show(
        const AppUpdatePresentation(phase: AppUpdatePhase.downloading),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      for (final phase in AppUpdatePhase.values) {
        await show(AppUpdatePresentation(phase: phase));
        expect(tester.getSize(find.byType(AppUpdateStrip)).height, 24);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
