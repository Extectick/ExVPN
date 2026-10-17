import 'package:exvpn/src/settings_navigation_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'icon, text and trailing arrow share one rounded navigation surface',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: SettingsNavigationRow(
                  icon: Icons.apps,
                  title: 'Applications',
                  subtitle: 'Where VPN works',
                  onTap: () => taps++,
                ),
              ),
            ),
          ),
        ),
      );
      final row = find.byType(SettingsNavigationRow);
      final material = tester.widget<Material>(
        find.descendant(of: row, matching: find.byType(Material)).first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(14));
      expect(material.clipBehavior, Clip.antiAlias);
      expect(
        find.descendant(of: row, matching: find.byType(ListTile)),
        findsOneWidget,
      );
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      expect(taps, 0);
      for (final target in [
        find.byIcon(Icons.apps),
        find.text('Applications'),
        find.text('Where VPN works'),
        find.byIcon(Icons.chevron_right),
      ]) {
        await tester.tap(target);
        await tester.pumpAndSettle();
      }
      expect(taps, 4);
      await pointer.removePointer();
      expect(tester.takeException(), isNull);
    },
  );
}
