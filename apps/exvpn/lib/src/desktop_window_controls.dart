// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_strings.dart';

const _channel = MethodChannel('exvpn/window');

Future<void> _windowAction(String action, [Object? arguments]) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await _channel.invokeMethod<void>(action, arguments);
  } on MissingPluginException {
    // Older native hosts and browser previews keep their own window frame.
  } on PlatformException {
    // Window presentation must not affect a running VPN session.
  }
}

Future<void> startDesktopWindowDrag() => _windowAction('startDrag');

/// The app header replaces only the native caption, keeping normal tray close.
class DesktopWindowControls extends StatefulWidget {
  const DesktopWindowControls({super.key});

  @override
  State<DesktopWindowControls> createState() => _DesktopWindowControlsState();
}

class _DesktopWindowControlsState extends State<DesktopWindowControls> {
  Color? _lastColor;
  Brightness? _lastBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    final color = theme.scaffoldBackgroundColor;
    if (_lastColor == color && _lastBrightness == theme.brightness) return;
    _lastColor = color;
    _lastBrightness = theme.brightness;
    _windowAction('setColors', {
      'background': color.toARGB32(),
      'dark': theme.brightness == Brightness.dark,
    });
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      HeaderIconButton(
        icon: CupertinoIcons.minus,
        tooltip: context.tr('Свернуть'),
        onPressed: () => _windowAction('minimize'),
      ),
      HeaderIconButton(
        icon: CupertinoIcons.xmark,
        tooltip: context.tr('Закрыть'),
        onPressed: () => _windowAction('close'),
      ),
    ],
  );
}

/// One shape, target and glyph size for all controls in the app header.
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    style: IconButton.styleFrom(
      fixedSize: const Size.square(34),
      minimumSize: const Size.square(34),
      maximumSize: const Size.square(34),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const CircleBorder(),
      foregroundColor: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      hoverColor: Theme.of(context).colorScheme.primary.withValues(alpha: .10),
      highlightColor: Theme.of(context).colorScheme.primary
          .withValues(alpha: .16),
    ),
    iconSize: 20,
    onPressed: onPressed,
    icon: Icon(icon),
  );
}
