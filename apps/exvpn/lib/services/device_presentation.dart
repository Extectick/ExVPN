// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A presentation hint from Android, never a heuristic based on screen width.
/// Tablets, phones in landscape and Windows retain their existing layouts.
Future<bool> isAndroidTelevision() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await const MethodChannel('exvpn/presentation')
            .invokeMethod<bool>('isTelevision')
            .timeout(const Duration(seconds: 2)) ==
        true;
  } catch (_) {
    return false;
  }
}
