import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Accessible connection action with one shared centre for all artwork.
/// The image's transparent margin is compensated without cropping its rim.
class PowerButton extends StatefulWidget {
  const PowerButton({
    super.key,
    required this.size,
    required this.onPressed,
    this.label = 'Подключить VPN',
    this.active = false,
    this.connecting = false,
    this.enabled = true,
  }) : assert(size > 0);

  final double size;
  final VoidCallback onPressed;
  final String label;
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
  bool _hovered = false;
  bool _focused = false;
  Timer? _keyboardFeedback;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(PowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connecting != widget.connecting) _syncPulse();
  }

  void _syncPulse() {
    if (widget.connecting && !MediaQuery.disableAnimationsOf(context)) {
      _wave.repeat(period: const Duration(milliseconds: 1400));
    } else if (!widget.connecting || MediaQuery.disableAnimationsOf(context)) {
      _wave.stop();
      _wave.value = 0;
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
    if (!MediaQuery.disableAnimationsOf(context)) {
      _wave.forward(from: 0);
    }
    // Visual feedback never delays the real action or invents VPN state.
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
    final highlighted =
        _hovered || _focused || widget.active || widget.connecting;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pressed = _pointerPressed || _keyboardPressed;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        focusNode: _focusNode,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
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
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
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
            child: SizedBox.square(
              dimension: widget.size,
              child: AnimatedScale(
                scale: pressed && !reduceMotion ? 0.97 : 1,
                alignment: Alignment.center,
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 110),
                curve: Curves.easeOutCubic,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: amber.withValues(
                                  alpha: highlighted || pressed ? 0.34 : 0,
                                ),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                              BoxShadow(
                                color: amber.withValues(
                                  alpha: highlighted || pressed ? 0.18 : 0,
                                ),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!reduceMotion)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _wave,
                            builder: (context, _) {
                              final progress = _wave.value;
                              final radius =
                                  20 * Curves.easeOutCubic.transform(progress);
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
                                        color: amber.withValues(
                                          alpha: fade * 0.85,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: amber.withValues(
                                            alpha: fade * 0.3,
                                          ),
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
                      ),
                    Positioned.fill(
                      child: OverflowBox(
                        alignment: Alignment.center,
                        maxWidth: widget.size * 1.18,
                        maxHeight: widget.size * 1.18,
                        child: Image.asset(
                          'assets/images/power-disc.png',
                          width: widget.size * 1.18,
                          height: widget.size * 1.18,
                          filterQuality: FilterQuality.medium,
                          cacheWidth: 768,
                          cacheHeight: 768,
                          excludeFromSemantics: true,
                        ),
                      ),
                    ),
                    // The outline paints beyond the nominal hit target. No ink
                    // layer is hidden behind the opaque disc or clipped by it.
                    Positioned(
                      left: -4,
                      top: -4,
                      right: -4,
                      bottom: -4,
                      child: IgnorePointer(
                        child: AnimatedContainer(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 120),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              width: 1.5,
                              color: _focused
                                  ? amber.withValues(alpha: 0.65)
                                  : amber.withValues(alpha: 0),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: widget.size * 0.088,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.power_settings_new_rounded,
                      size: widget.size * 0.39,
                      color: amber,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
