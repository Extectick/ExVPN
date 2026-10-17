// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Contains only display preferences, never subscriptions or VPN settings.
Future<File> _file(bool preview) async {
  final directory = await getApplicationSupportDirectory();
  return File(
    '${directory.path}${Platform.pathSeparator}'
    '${preview ? 'design-appearance' : 'appearance'}-v1.json',
  );
}

Future<String?> readAppearance({required bool preview}) async {
  final file = await _file(preview);
  if (!await file.exists()) return null;
  if (await file.length() > 4096) throw const FormatException();
  final raw = await file.readAsString();
  if (raw.length > 4096) throw const FormatException();
  return raw;
}

Future<void> writeAppearance(String raw, {required bool preview}) async {
  if (raw.length > 4096) throw const FormatException();
  final file = await _file(preview);
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(raw, flush: true);
  await temporary.rename(file.path);
}
