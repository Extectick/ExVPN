// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'qr_import.dart';

const qrCameraAvailable = true;

@JS('navigator')
external _Navigator get _navigator;
@JS('document')
external _Document get _document;

extension type _Navigator(JSObject _) implements JSObject {
  external _Clipboard? get clipboard;
  external _MediaDevices? get mediaDevices;
}

extension type _Clipboard(JSObject _) implements JSObject {
  external JSPromise<JSArray<_ClipboardItem>> read();
}

extension type _ClipboardItem(JSObject _) implements JSObject {
  external JSArray<JSString> get types;
  external JSPromise<_Blob> getType(String type);
}

extension type _Blob(JSObject _) implements JSObject {
  external int get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _Document(JSObject _) implements JSObject {
  external JSObject createElement(String tag);
}

extension type _MediaDevices(JSObject _) implements JSObject {
  external JSPromise<_MediaStream> getUserMedia(_Constraints constraints);
}

extension type _Constraints._(JSObject _) implements JSObject {
  external _Constraints({bool audio, _VideoConstraints video});
}

extension type _VideoConstraints._(JSObject _) implements JSObject {
  external _VideoConstraints({String facingMode, int width, int height});
}

extension type _MediaStream(JSObject _) implements JSObject {
  external JSArray<_MediaTrack> getTracks();
}

extension type _MediaTrack(JSObject _) implements JSObject {
  external void stop();
}

extension type _Style(JSObject _) implements JSObject {
  external set cssText(String value);
}

extension type _Video(JSObject _) implements JSObject {
  external _Style get style;
  external set srcObject(_MediaStream? stream);
  external set muted(bool value);
  external set autoplay(bool value);
  external set playsInline(bool value);
  external int get videoWidth;
  external int get videoHeight;
  external JSPromise<JSAny?> play();
  external void pause();
}

extension type _Canvas(JSObject _) implements JSObject {
  external set width(int value);
  external set height(int value);
  external _CanvasContext? getContext(String kind);
  external String toDataURL(String mime);
}

extension type _CanvasContext(JSObject _) implements JSObject {
  external void drawImage(_Video source, int x, int y, int width, int height);
}

bool _readingClipboard = false;

Future<String?> readQrClipboard() async {
  if (_readingClipboard) return null;
  _readingClipboard = true;
  final watch = Stopwatch()..start();
  const deadline = Duration(seconds: 20);
  Duration remaining() {
    final duration = deadline - watch.elapsed;
    if (duration <= Duration.zero) throw TimeoutException('clipboard');
    return duration;
  }

  try {
    final clipboard = _navigator.clipboard;
    if (clipboard == null) return null;
    final items = await clipboard.read().toDart.timeout(remaining());
    for (final item in items.toDart.take(8)) {
      final types = item.types.toDart.map((type) => type.toDart);
      final type = types.contains('image/png')
          ? 'image/png'
          : types.contains('image/jpeg')
          ? 'image/jpeg'
          : null;
      if (type == null) continue;
      final blob = await item.getType(type).toDart.timeout(remaining());
      if (blob.size <= 0) continue;
      if (blob.size > qrMaxBytes) {
        throw const QrImportException(QrImportError.tooLarge);
      }
      final buffer = await blob.arrayBuffer().toDart.timeout(remaining());
      final bytes = buffer.toDart.asUint8List();
      if (bytes.length > qrMaxBytes) {
        throw const QrImportException(QrImportError.tooLarge);
      }
      try {
        return await decodeQrImage(bytes).timeout(remaining());
      } on QrImportException catch (error) {
        if (error.code != QrImportError.notFound) rethrow;
      }
    }
    return null;
  } on QrImportException {
    rethrow;
  } catch (_) {
    // Browsers can deny clipboard access or not implement image reads. The
    // caller offers its regular file picker; no clipboard details are logged.
    return null;
  } finally {
    _readingClipboard = false;
  }
}

Widget qrCameraView({
  required ValueChanged<String> onDetected,
  required VoidCallback onClose,
}) => _QrCamera(onDetected: onDetected, onClose: onClose);

class _QrCamera extends StatefulWidget {
  const _QrCamera({required this.onDetected, required this.onClose});
  final ValueChanged<String> onDetected;
  final VoidCallback onClose;

  @override
  State<_QrCamera> createState() => _QrCameraState();
}

class _QrCameraState extends State<_QrCamera> {
  _Video? _video;
  _MediaStream? _stream;
  Timer? _timer;
  bool _stopped = false;
  bool _decoding = false;
  bool _ready = false;
  bool _failed = false;

  Future<void> _start(Object element) async {
    final video = _Video(element as JSObject);
    _video = video;
    video.style.cssText =
        'width:100%;height:100%;object-fit:cover;background:#101214;';
    video.muted = true;
    video.autoplay = true;
    video.playsInline = true;
    try {
      final devices = _navigator.mediaDevices;
      if (devices == null) throw StateError('camera unavailable');
      final request = devices
          .getUserMedia(
            _Constraints(
              audio: false,
              video: _VideoConstraints(
                facingMode: 'environment',
                width: 1280,
                height: 720,
              ),
            ),
          )
          .toDart;
      // Permission prompts cannot be cancelled by the page. A late granted
      // stream must be stopped even if the dialog has already been dismissed.
      unawaited(
        request.then<void>((stream) {
          if (_stopped || !mounted) _stopStream(stream);
        }, onError: (Object _) {}),
      );
      final stream = await request.timeout(const Duration(seconds: 20));
      if (_stopped || !mounted) {
        _stopStream(stream);
        return;
      }
      _stream = stream;
      video.srcObject = stream;
      await video.play().toDart.timeout(const Duration(seconds: 5));
      if (_stopped || !mounted) return;
      setState(() => _ready = true);
      _timer = Timer.periodic(const Duration(milliseconds: 650), (_) {
        unawaited(_scanFrame());
      });
    } catch (_) {
      _stop();
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _scanFrame() async {
    if (_stopped || _decoding || !mounted) return;
    final video = _video;
    if (video == null || video.videoWidth <= 0 || video.videoHeight <= 0) {
      return;
    }
    _decoding = true;
    try {
      // Scale before encoding: at most 960×960 pixels, comfortably below the
      // existing decoder's byte/pixel/candidate limits. One frame at a time.
      final scale = math.min(
        1.0,
        960 / math.max(video.videoWidth, video.videoHeight),
      );
      final width = math.max(1, (video.videoWidth * scale).round());
      final height = math.max(1, (video.videoHeight * scale).round());
      final canvas = _Canvas(_document.createElement('canvas'));
      canvas.width = width;
      canvas.height = height;
      final context = canvas.getContext('2d');
      if (context == null) return;
      context.drawImage(video, 0, 0, width, height);
      final encoded = canvas.toDataURL('image/png');
      const prefix = 'data:image/png;base64,';
      if (!encoded.startsWith(prefix) ||
          encoded.length > prefix.length + ((qrMaxBytes + 2) ~/ 3) * 4) {
        return;
      }
      final text = await decodeQrImage(
        base64Decode(encoded.substring(prefix.length)),
      );
      if (_stopped || !mounted) return;
      _stop();
      widget.onDetected(text);
    } catch (_) {
      // A frame without a QR is normal. QR content is only returned to preview,
      // never followed as a URL, evaluated, or written to diagnostic output.
    } finally {
      _decoding = false;
    }
  }

  void _stopStream(_MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  void _stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) _stopStream(stream);
    _video?.pause();
    _video?.srcObject = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 36),
              const SizedBox(height: 16),
              Text(
                ru
                    ? 'Камера недоступна. Проверьте разрешение в браузере.'
                    : 'Camera unavailable. Check your browser permission.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.onClose,
                child: Text(ru ? 'Закрыть' : 'Close'),
              ),
            ],
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          HtmlElementView.fromTagName(
            tagName: 'video',
            onElementCreated: _start,
          ),
          if (!_ready) const Center(child: CircularProgressIndicator()),
          if (_ready)
            const Center(
              child: IgnorePointer(
                child: SizedBox(
                  width: 210,
                  height: 210,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.fromBorderSide(
                        BorderSide(color: Colors.white70, width: 2),
                      ),
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
