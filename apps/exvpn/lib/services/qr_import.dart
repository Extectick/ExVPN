import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:zxing2/qrcode.dart';

enum QrImportError {
  tooLarge,
  tooComplex,
  unsupportedImage,
  notFound,
  unreadable,
}

final class QrImportException implements Exception {
  const QrImportException(this.code);
  final QrImportError code;
  @override
  String toString() => 'QrImportException(${code.name})';
}

const qrMaxBytes = 5 * 1024 * 1024;
const qrMaxPixels = 4 * 1024 * 1024;
const qrMaxCandidates = 128;

/// Reading a QR never follows its URL or imports a profile. The dialog previews
/// the result and reuses the normal validated import only after confirmation.
Future<String?> pickQrText() async {
  try {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'QR PNG / JPEG',
          extensions: ['png', 'jpg', 'jpeg'],
          mimeTypes: ['image/png', 'image/jpeg'],
          uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
        ),
      ],
    );
    if (file == null) return null;
    return await decodeQrImage(await readQrFile(file));
  } on QrImportException {
    rethrow;
  } catch (_) {
    // Filenames, picker/provider errors and decoded secrets are never logged.
    throw const QrImportException(QrImportError.unreadable);
  }
}

/// The selected file may be backed by a stalled document/cloud provider. Bound
/// metadata + complete body by one deadline, and cancel without awaiting a
/// provider's potentially stalled cancellation future. The OS picker itself is
/// user-controlled and is not timed out.
Future<Uint8List> readQrFile(
  XFile file, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (timeout <= Duration.zero) {
    throw const QrImportException(QrImportError.unreadable);
  }
  final watch = Stopwatch()..start();
  try {
    final length = await file.length().timeout(timeout);
    if (length < 0) throw const QrImportException(QrImportError.unreadable);
    if (length > qrMaxBytes) {
      throw const QrImportException(QrImportError.tooLarge);
    }
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const QrImportException(QrImportError.unreadable);
    }
    final result = Completer<Uint8List>();
    final output = BytesBuilder(copy: false);
    final deadline = Timer(remaining, () {
      if (!result.isCompleted) {
        result.completeError(const QrImportException(QrImportError.unreadable));
      }
    });
    StreamSubscription<Uint8List>? subscription;
    try {
      subscription = file.openRead().listen(
        (chunk) {
          if (result.isCompleted) return;
          if (output.length + chunk.length > qrMaxBytes) {
            result.completeError(
              const QrImportException(QrImportError.tooLarge),
            );
          } else {
            output.add(chunk);
          }
        },
        onError: (Object _) {
          if (!result.isCompleted) {
            result.completeError(
              const QrImportException(QrImportError.unreadable),
            );
          }
        },
        onDone: () {
          if (!result.isCompleted) result.complete(output.takeBytes());
        },
        cancelOnError: false,
      );
      return await result.future;
    } finally {
      deadline.cancel();
      output.clear();
      if (subscription != null) {
        // Do not retain input buffers or block UI on a broken provider cancel.
        unawaited(subscription.cancel().catchError((Object _) {}));
      }
    }
  } on QrImportException {
    rethrow;
  } catch (_) {
    throw const QrImportException(QrImportError.unreadable);
  }
}

Future<String> decodeQrImage(Uint8List bytes) async {
  if (bytes.length > qrMaxBytes) {
    throw const QrImportException(QrImportError.tooLarge);
  }
  final png =
      bytes.length >= 8 &&
      listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  if (!png && !jpeg) {
    throw const QrImportException(QrImportError.unsupportedImage);
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 ||
        descriptor.height <= 0 ||
        descriptor.width > 4096 ||
        descriptor.height > 4096 ||
        descriptor.width * descriptor.height > qrMaxPixels) {
      throw const QrImportException(QrImportError.tooLarge);
    }
    // Use the platform/Flutter image codec; do not inflate arbitrary PNG streams
    // with an unbounded Dart decompressor. Dimensions are checked before pixels.
    codec = await descriptor.instantiateCodec();
    if (codec.frameCount != 1) {
      throw const QrImportException(QrImportError.unsupportedImage);
    }
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) throw const QrImportException(QrImportError.unreadable);
    return await compute(_decodePixels, (
      image.width,
      image.height,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ));
  } on QrImportException {
    rethrow;
  } catch (_) {
    throw const QrImportException(QrImportError.unreadable);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

String _decodePixels((int, int, Uint8List) input) {
  final (width, height, rgba) = input;
  final pixels = Int32List(width * height);
  for (var i = 0; i < pixels.length; i++) {
    final at = i * 4, alpha = rgba[at + 3];
    int whiteComposite(int channel) =>
        (channel * alpha + 255 * (255 - alpha)) ~/ 255;
    pixels[i] =
        (whiteComposite(rgba[at]) << 16) |
        (whiteComposite(rgba[at + 1]) << 8) |
        whiteComposite(rgba[at + 2]);
  }
  final source = RGBLuminanceSource(width, height, pixels);
  for (final luminance in [source, source.invert()]) {
    try {
      var candidates = 0;
      final hints = DecodeHints()
        ..put(DecodeHintType.needResultPointCallback, (_) {
          // zxing2 chooses triples of finder candidates. Pixel limits alone do
          // not bound that cubic search: a small false-marker grid is sufficient.
          if (++candidates > qrMaxCandidates) {
            throw const QrImportException(QrImportError.tooComplex);
          }
        });
      final text = QRCodeReader()
          .decode(BinaryBitmap(HybridBinarizer(luminance)), hints: hints)
          .text
          .trim();
      if (text.isEmpty || text.length > 8192 || text.contains('\u0000')) {
        throw const QrImportException(QrImportError.notFound);
      }
      return text;
    } on QrImportException {
      rethrow; // A hard resource limit must not retry the inverted branch.
    } catch (_) {
      // Retry the inverted image without exposing decoder data in errors.
    }
  }
  throw const QrImportException(QrImportError.notFound);
}
