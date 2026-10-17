import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A fixed logical canvas. Resizing the desktop window scales this canvas.
enum DesktopLayout { minimal, medium, large }

extension DesktopLayoutPresentation on DesktopLayout {
  Size get canvasSize => switch (this) {
    DesktopLayout.minimal => const Size(400, 440),
    DesktopLayout.medium => const Size(440, 760),
    DesktopLayout.large => const Size(1040, 680),
  };

  String get label => switch (this) {
    DesktopLayout.minimal => 'Минимальный',
    DesktopLayout.medium => 'Средний',
    DesktopLayout.large => 'Большой',
  };
}

const _windowChannel = MethodChannel('exvpn/window');

/// Window presentation is optional on web, mobile and older desktop hosts.
Future<void> applyDesktopLayout(DesktopLayout mode) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await _windowChannel.invokeMethod<void>('setLayout', {'mode': mode.name});
  } on MissingPluginException {
    // A preview or an older host can still scale the Flutter canvas itself.
  } on PlatformException {
    // A window-manager failure must not interrupt the app or the VPN session.
  }
}
