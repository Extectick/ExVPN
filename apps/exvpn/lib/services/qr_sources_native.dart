// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'qr_import.dart';

/// Desktop clipboard file paths only; binary image clipboard support is not
/// provided by Flutter's text clipboard. The caller can fall back to the picker.
Future<String?> readQrClipboard() async {
  final watch = Stopwatch()..start();
  const deadline = Duration(seconds: 20);
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain)
        .timeout(deadline);
    var path = data?.text?.trim();
    if (path == null || path.isEmpty || path.length > 4096) return null;
    if (path.startsWith('"') && path.endsWith('"')) {
      path = path.substring(1, path.length - 1);
    }
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'file') {
      if (uri!.host.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
      path = uri.toFilePath(windows: Platform.isWindows);
    }
    if (path.startsWith(r'\\') || path.startsWith('//')) return null;
    final absolute = Platform.isWindows
        ? RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)
        : path.startsWith('/');
    if (!absolute ||
        !RegExp(r'\.(png|jpe?g)$', caseSensitive: false).hasMatch(path)) {
      return null;
    }
    if (await FileSystemEntity.type(
          path,
          followLinks: false,
        ).timeout(deadline - watch.elapsed) !=
        FileSystemEntityType.file) {
      return null;
    }
    final remaining = deadline - watch.elapsed;
    if (remaining <= Duration.zero) return null;
    return await decodeQrImage(
      await readQrFile(XFile(path), timeout: remaining),
    );
  } on QrImportException catch (error) {
    if (error.code == QrImportError.notFound) return null;
    rethrow;
  } catch (_) {
    // Clipboard/provider data, paths and errors must not reach diagnostics.
    return null;
  }
}

Widget qrCameraView({
  required ValueChanged<String> onDetected,
  required VoidCallback onClose,
}) => _CameraUnavailable(onClose: onClose);

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
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
                  ? 'Камера пока недоступна. Выберите QR из изображения.'
                  : 'Camera is not available yet. Select a QR image instead.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onClose,
              child: Text(ru ? 'Закрыть' : 'Close'),
            ),
          ],
        ),
      ),
    );
  }
}
