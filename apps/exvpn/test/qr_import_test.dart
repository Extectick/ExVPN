import 'dart:async';
import 'dart:typed_data';

import 'package:exvpn/services/qr_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

const _value = 'https://example.invalid/sub/synthetic-test';

img.Image _qr(String text, {bool inverted = false}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  const scale = 6, border = 4;
  final result = img.Image(
    width: (matrix.width + border * 2) * scale,
    height: (matrix.height + border * 2) * scale,
    numChannels: 4,
  );
  final bg = inverted ? 0 : 255, fg = inverted ? 255 : 0;
  img.fill(result, color: img.ColorRgba8(bg, bg, bg, 255));
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) != 1) continue;
      img.fillRect(
        result,
        x1: (x + border) * scale,
        y1: (y + border) * scale,
        x2: (x + border + 1) * scale - 1,
        y2: (y + border + 1) * scale - 1,
        color: img.ColorRgba8(fg, fg, fg, 255),
      );
    }
  }
  return result;
}

Matcher failure(QrImportError code) =>
    throwsA(isA<QrImportException>().having((e) => e.code, 'code', code));

class ProviderFile extends XFile {
  ProviderFile(this.size, this.stream) : super('synthetic-provider-file');
  final Future<int> size;
  final Stream<Uint8List> stream;
  @override
  Future<int> length() => size;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) => stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real PNG and JPEG QR decoding returns text without using network',
    () async {
      final bitmap = _qr(_value);
      expect(
        await decodeQrImage(Uint8List.fromList(img.encodePng(bitmap))),
        _value,
      );
      expect(
        await decodeQrImage(
          Uint8List.fromList(img.encodeJpg(bitmap, quality: 95)),
        ),
        _value,
      );
    },
  );
  test('inverted QR and rotated QR decode', () async {
    final inverted = _qr(_value, inverted: true);
    expect(
      await decodeQrImage(Uint8List.fromList(img.encodePng(inverted))),
      _value,
    );
    final rotated = img.copyRotate(_qr(_value), angle: 90);
    expect(
      await decodeQrImage(Uint8List.fromList(img.encodePng(rotated))),
      _value,
    );
  });
  test(
    'opaque black QR on transparent background composites over white',
    () async {
      final bitmap = _qr(_value);
      for (final pixel in bitmap) {
        if (pixel.r == 255) pixel.a = 0;
      }
      expect(
        await decodeQrImage(Uint8List.fromList(img.encodePng(bitmap))),
        _value,
      );
    },
  );
  test('untrusted QR schemes are data, not navigation or code', () async {
    const text = 'javascript:synthetic-no-execution';
    expect(
      await decodeQrImage(Uint8List.fromList(img.encodePng(_qr(text)))),
      text,
    );
  });
  test('file byte and declared pixel limits are checked', () async {
    await expectLater(
      decodeQrImage(Uint8List(qrMaxBytes + 1)),
      failure(QrImportError.tooLarge),
    );
    final wide = img.Image(width: 4097, height: 1);
    await expectLater(
      decodeQrImage(Uint8List.fromList(img.encodePng(wide))),
      failure(QrImportError.tooLarge),
    );
  });
  test('unsupported bytes and broken PNG report fixed errors', () async {
    await expectLater(
      decodeQrImage(Uint8List.fromList([1, 2, 3])),
      failure(QrImportError.unsupportedImage),
    );
    await expectLater(
      decodeQrImage(
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]),
      ),
      failure(QrImportError.unreadable),
    );
  });
  test('ordinary image without a code fails safely', () async {
    final bitmap = img.Image(width: 100, height: 100);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    await expectLater(
      decodeQrImage(Uint8List.fromList(img.encodePng(bitmap))),
      failure(QrImportError.notFound),
    );
  });

  test(
    'small false-finder grid is rejected before cubic candidate search',
    () async {
      // Only 512x512, well below the pixel/byte caps. Without the candidate cap
      // this creates >3500 candidates and reaches the O(n^3) triple search.
      final bitmap = img.Image(width: 512, height: 512);
      img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
      for (var oy = 2; oy + 7 < bitmap.height; oy += 8) {
        for (var ox = 2; ox + 7 < bitmap.width; ox += 8) {
          for (var y = 0; y < 7; y++) {
            for (var x = 0; x < 7; x++) {
              if (x == 0 ||
                  x == 6 ||
                  y == 0 ||
                  y == 6 ||
                  (x >= 2 && x <= 4 && y >= 2 && y <= 4)) {
                bitmap.setPixelRgb(ox + x, oy + y, 0, 0, 0);
              }
            }
          }
        }
      }
      await expectLater(
        decodeQrImage(Uint8List.fromList(img.encodePng(bitmap)))
            .timeout(const Duration(seconds: 5)),
        failure(QrImportError.tooComplex),
      );
    },
  );

  test('stalled selected-file metadata has a bounded deadline', () async {
    final metadata = Completer<int>();
    await expectLater(
      readQrFile(
        ProviderFile(metadata.future, const Stream.empty()),
        timeout: const Duration(milliseconds: 20),
      ),
      failure(QrImportError.unreadable),
    );
    metadata.complete(0);
  });

  test(
    'stalled body cancels promptly even when provider cancellation stalls',
    () async {
      var cancelled = false;
      final cancelFinished = Completer<void>();
      final body = StreamController<Uint8List>(
        onCancel: () {
          cancelled = true;
          return cancelFinished.future;
        },
      );
      await expectLater(
        readQrFile(
          ProviderFile(Future.value(10), body.stream),
          timeout: const Duration(milliseconds: 20),
        ).timeout(const Duration(seconds: 2)),
        failure(QrImportError.unreadable),
      );
      expect(cancelled, true);
      cancelFinished.complete();
      await body.close();
    },
  );

  test(
    'streamed size limit cancels before provider can exceed metadata claim',
    () async {
      var cancelled = false;
      final body = StreamController<Uint8List>(
        onCancel: () {
          cancelled = true;
        },
      );
      final read = readQrFile(ProviderFile(Future.value(1), body.stream));
      final failureExpectation = expectLater(
        read,
        failure(QrImportError.tooLarge),
      );
      body.add(Uint8List(qrMaxBytes + 1));
      await failureExpectation;
      expect(cancelled, true);
      await body.close();
      expect(
        await readQrFile(
          ProviderFile(
            Future.value(3),
            Stream.value(Uint8List.fromList([1, 2, 3])),
          ),
        ),
        [1, 2, 3],
      );
    },
  );
}
