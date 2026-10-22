// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A presentation hint from Android, never a heuristic based on screen width.
/// Retry transient engine/channel startup failures before selecting a layout.
Future<bool> isAndroidTelevision({
  @visibleForTesting Duration requestTimeout = const Duration(seconds: 2),
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      return await const MethodChannel('exvpn/presentation')
              .invokeMethod<bool>('isTelevision')
              .timeout(requestTimeout) ==
          true;
    } on TimeoutException {
      // A slow first native frame must not permanently classify a TV as a phone.
    } on MissingPluginException {
      // The engine may start Dart just before the activity installs its handler.
    } catch (_) {
      return false;
    }
    if (attempt < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return false;
}
