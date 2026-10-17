import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exvpn/src/application_icon.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' show FakeBridge;

class IconBridge extends FakeBridge implements ApplicationIconBridge {
  Future<Uint8List?> Function(String)? readIcon;
  int reads = 0;
  @override
  Future<Uint8List?> getApplicationIcon(String id) {
    reads++;
    return readIcon!(id);
  }
}

void main() {
  testWidgets(
    'a real application PNG is rendered and reused for the same exact ID',
    (tester) async {
      final png = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 64);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return bytes!.buffer.asUint8List();
      });
      final bridge = IconBridge()..readIcon = (_) async => png;
      final cache = ApplicationIconCache(bridge);
      addTearDown(cache.dispose);
      addTearDown(bridge.close);
      final icon = cache.load('C:/Apps/Example/example.exe');
      expect(
        identical(icon, cache.load('C:/Apps/Example/example.exe')),
        isTrue,
      );
      await tester.pumpWidget(MaterialApp(home: ApplicationIcon(icon: icon)));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(bridge.reads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing, invalid or failed native icons keep a usable fallback',
    (tester) async {
      final bridge = IconBridge();
      final cache = ApplicationIconCache(bridge);
      addTearDown(cache.dispose);
      addTearDown(bridge.close);
      for (final failure in ['missing', 'invalid', 'failed']) {
        bridge.readIcon = (_) async {
          if (failure == 'failed') throw StateError('native icon unavailable');
          return failure == 'missing' ? null : Uint8List.fromList([1, 2, 3]);
        };
        await tester.pumpWidget(
          MaterialApp(home: ApplicationIcon(icon: cache.load(failure))),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNothing);
        expect(find.byIcon(Icons.apps_rounded), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
