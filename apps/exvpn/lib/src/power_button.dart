import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_strings.dart';
import 'theme.dart';

/// Accessible connection action with one shared centre for all artwork.
/// The image's transparent margin is compensated without cropping its rim.
class PowerButton extends StatefulWidget {
  const PowerButton({
    super.key,
    required this.size,
    required this.onPressed,
    this.label = 'Подключить VPN',
    this.elapsedLabel,
    this.active = false,
    this.connecting = false,
    this.enabled = true,
  }) : assert(size > 0);

  final double size;
  final VoidCallback onPressed;
  final String label;
  final String? elapsedLabel;
  final bool active;
  final bool connecting;
  final bool enabled;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 640),
  );
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'VPN connection',
    onKeyEvent: (_, event) {
      // Unhandled repeats would bubble to MaterialApp's default ActivateIntent
      // shortcuts and accidentally run the action again.
      if (event is KeyRepeatEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );
  bool _pointerPressed = false;
  bool _keyboardPressed = false;
  bool _focused = false;
  Timer? _keyboardFeedback;

  bool get _illuminated => widget.active || widget.connecting;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(PowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connecting != widget.connecting ||
        oldWidget.active != widget.active) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    if (!_illuminated || MediaQuery.disableAnimationsOf(context)) {
      _wave.stop();
      _wave.value = 0;
    } else if (widget.connecting) {
      _wave.repeat(period: const Duration(milliseconds: 1400));
    } else {
      _wave.forward(from: 0);
    }
  }

  void _setPointerPressed(bool value) {
    if (_pointerPressed == value) return;
    setState(() => _pointerPressed = value);
  }

  void _activateFromKeyboard() {
    if (!widget.enabled) return;
    _keyboardFeedback?.cancel();
    setState(() => _keyboardPressed = true);
    _keyboardFeedback = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _keyboardPressed = false);
    });
    _activate();
  }

  void _activate() {
    if (!widget.enabled) return;
    // Visual feedback never delays the real action or invents VPN state.
    // The wave follows the confirmed state, so Disconnect cannot leave a ring.
    widget.onPressed();
  }

  @override
  void dispose() {
    _keyboardFeedback?.cancel();
    _wave.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final illuminated = _illuminated;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final visuals = theme.extension<ExVpnVisuals>();
    final glowColor = visuals?.glowColor ?? scheme.primary;
    final discColor =
        visuals?.buttonColor ??
        (light ? const Color(0xfff5f9fc) : const Color(0xff25282a));
    final idleColor = light ? const Color(0xff8d9faa) : const Color(0xff737980);
    final symbolColor = illuminated ? scheme.primary : idleColor;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pressed = _pointerPressed || _keyboardPressed;
    final image = Image.asset(
      'assets/images/power-disc.png',
      width: widget.size * 1.18,
      height: widget.size * 1.18,
      filterQuality: FilterQuality.medium,
      cacheWidth: 768,
      cacheHeight: 768,
      excludeFromSemantics: true,
    );
    final tintDisc = light || discColor != const Color(0xff25282a);
    final artwork = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: AnimatedContainer(
            duration: reduceMotion || !illuminated
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(
                    alpha: illuminated ? (light ? .42 : .34) : 0,
                  ),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
                BoxShadow(
                  color: glowColor.withValues(alpha: illuminated ? .18 : 0),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
        if (illuminated && !reduceMotion)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _wave,
              builder: (context, _) {
                final progress = _wave.value;
                final radius = 20 * Curves.easeOutCubic.transform(progress);
                final fade = _wave.isAnimating
                    ? (1 - progress) * (1 - progress)
                    : 0.0;
                final diameter = widget.size + radius * 2;
                return OverflowBox(
                  alignment: Alignment.center,
                  maxWidth: diameter,
                  maxHeight: diameter,
                  child: SizedBox.square(
                    dimension: diameter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: 2.5,
                          color: glowColor.withValues(alpha: fade * .85),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: glowColor.withValues(alpha: fade * .3),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        Positioned.fill(
          child: OverflowBox(
            alignment: Alignment.center,
            maxWidth: widget.size * 1.18,
            maxHeight: widget.size * 1.18,
            // Positive luminance contrast keeps the original texture and
            // highlight direction. Alpha and the transparent rim are untouched.
            child: tintDisc
                ? ColorFiltered(
                    colorFilter: ColorFilter.matrix([
                      .2126,
                      .7152,
                      .0722,
                      0,
                      discColor.r * 255 - 38,
                      .2126,
                      .7152,
                      .0722,
                      0,
                      discColor.g * 255 - 38,
                      .2126,
                      .7152,
                      .0722,
                      0,
                      discColor.b * 255 - 38,
                      0,
                      0,
                      0,
                      1,
                      0,
                    ]),
                    child: image,
                  )
                : image,
          ),
        ),
        Positioned(
          left: -4,
          top: -4,
          right: -4,
          bottom: -4,
          child: AnimatedContainer(
            duration: reduceMotion || !illuminated
                ? Duration.zero
                : const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                width: 1.5,
                color: symbolColor.withValues(alpha: _focused ? .65 : 0),
              ),
            ),
          ),
        ),
        Positioned(
          top: widget.size * .088,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: symbolColor,
              shape: BoxShape.circle,
            ),
          ),
        ),
        Icon(
          Icons.power_settings_new_rounded,
          size: widget.size * .39,
          color: symbolColor,
        ),
        if (widget.elapsedLabel case final elapsedLabel?)
          Positioned(
            top: widget.size * .755,
            left: 0,
            right: 0,
            child: ExcludeSemantics(
              child: Text(
                elapsedLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: illuminated
                      ? (light
                            ? scheme.primary.withValues(alpha: .85)
                            : Colors.white.withValues(alpha: .72))
                      : idleColor,
                  fontSize: widget.size * .064,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: widget.size * .004,
                ),
              ),
            ),
          ),
      ],
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: context.tr(widget.label),
      value: widget.elapsedLabel,
      onTap: widget.enabled ? _activate : null,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        focusNode: _focusNode,
        mouseCursor: SystemMouseCursors.basic,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activateFromKeyboard();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        child: SizedBox.square(
          dimension: widget.size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Artwork can paint its glow outside the disk. It never receives
              // pointer events; only the separate circular target below does.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedScale(
                    scale: pressed && !reduceMotion ? .97 : 1,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 110),
                    curve: Curves.easeOutCubic,
                    child: artwork,
                  ),
                ),
              ),
              Positioned.fill(
                child: ClipOval(
                  child: MouseRegion(
                    cursor: widget.enabled
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: !widget.enabled
                          ? null
                          : (_) {
                              _focusNode.requestFocus();
                              _setPointerPressed(true);
                            },
                      onTapUp: (_) => _setPointerPressed(false),
                      onTapCancel: () => _setPointerPressed(false),
                      onTap: widget.enabled ? _activate : null,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
