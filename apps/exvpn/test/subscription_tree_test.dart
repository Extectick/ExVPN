import 'package:exvpn/src/subscription_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('compact tree keeps natural row heights in $direction', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Center(
              child: SizedBox(
                width: 320,
                child: SubscriptionTree(
                  key: const Key('tree'),
                  children: [
                    SizedBox(
                      key: const Key('short'),
                      height: 56,
                      child: TextButton(
                        onPressed: () => taps++,
                        child: const Text('Server'),
                      ),
                    ),
                    const SizedBox(key: Key('tall'), height: 96),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final tree = tester.getRect(find.byKey(const Key('tree')));
      final short = tester.getRect(find.byKey(const Key('short')));
      final tall = tester.getRect(find.byKey(const Key('tall')));
      expect(tree.height, 152);
      expect(tall.top, short.bottom);
      expect(short.width, 296);
      expect(
        direction == TextDirection.ltr
            ? short.left - tree.left
            : tree.right - short.right,
        24,
      );
      await tester.tap(find.text('Server'));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty and wrapped rows do not leave a fixed-height rail', (
    tester,
  ) async {
    Widget content(List<Widget> children) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: SizedBox(
              width: 320,
              child: SubscriptionTree(
                key: const Key('tree'),
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      content(const [
        Text('Длинное наименование сервера с переносом на несколько строк'),
        SizedBox(height: 56),
      ]),
    );
    final wrapped = tester.getSize(find.byType(Text));
    expect(wrapped.height, greaterThan(40));
    expect(
      tester.getSize(find.byKey(const Key('tree'))).height,
      wrapped.height + 56,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(content(const []));
    expect(tester.getSize(find.byKey(const Key('tree'))).height, 0);
    expect(tester.takeException(), isNull);
  });
}
