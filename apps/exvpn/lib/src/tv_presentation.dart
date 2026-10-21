// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Device presentation only. It never changes VPN policy or connection state.
class TvPresentation extends InheritedWidget {
  const TvPresentation({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvPresentation>()?.enabled ==
      true;
  @override
  bool updateShouldNotify(TvPresentation oldWidget) =>
      enabled != oldWidget.enabled;
}

class _TvActivateIntent extends Intent {
  const _TvActivateIntent();
}

class _TvBackIntent extends Intent {
  const _TvBackIntent();
}

/// Below MaterialApp's text-editing shortcuts, so Up/Down can leave input fields.
/// Left/Right still edit text. Android's system Back is handled by Navigator.
class TvAppPresentation extends StatefulWidget {
  const TvAppPresentation({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  State<TvAppPresentation> createState() => _TvAppPresentationState();
}

class _TvAppPresentationState extends State<TvAppPresentation> {
  static final _highlightLeases = <Object>{};
  static FocusHighlightStrategy? _previousHighlight;
  final _highlightLease = Object();
  @override
  void initState() {
    super.initState();
    _syncHighlight();
  }

  @override
  void didUpdateWidget(TvAppPresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _syncHighlight();
  }

  void _syncHighlight() {
    if (widget.enabled) {
      _previousHighlight ??= FocusManager.instance.highlightStrategy;
      _highlightLeases.add(_highlightLease);
    } else {
      _highlightLeases.remove(_highlightLease);
    }
    _scheduleHighlight();
  }

  static void _scheduleHighlight() {
    // FocusableActionDetector listeners cannot be notified during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_highlightLeases.isNotEmpty) {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
      } else if (_previousHighlight != null) {
        FocusManager.instance.highlightStrategy = _previousHighlight!;
        _previousHighlight = null;
      }
    });
  }

  @override
  void dispose() {
    _highlightLeases.remove(_highlightLease);
    _scheduleHighlight();
    super.dispose();
  }

  void _activate() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return;
    var editor = focused.findAncestorStateOfType<EditableTextState>();
    void findEditor(Element element) {
      if (editor != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        editor = element.state as EditableTextState;
      } else {
        element.visitChildren(findEditor);
      }
    }

    if (editor == null &&
        FocusManager.instance.primaryFocus is! FocusScopeNode) {
      focused.visitChildElements(findEditor);
    }
    final field = editor;
    if (field != null) {
      field.requestKeyboard();
      return;
    }
    Actions.maybeInvoke(focused, const ActivateIntent());
  }

  void _back() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final navigator = focused == null ? null : Navigator.maybeOf(focused);
    // Do not exit the application from a keyboard helper or stop its VPN service.
    // The physical Android Back retains the platform's normal root behavior.
    navigator?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return TvPresentation(enabled: false, child: widget.child);
    }
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final focusSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: primary, width: 2)
          : null,
    );
    final media = MediaQuery.of(context);
    return TvPresentation(
      enabled: true,
      child: MediaQuery(
        data: media.copyWith(
          textScaler: media.textScaler.clamp(minScaleFactor: 1.2),
        ),
        child: Theme(
          data: theme.copyWith(
            focusColor: primary.withValues(alpha: .25),
            visualDensity: VisualDensity.standard,
            iconButtonTheme: IconButtonThemeData(
              style: ButtonStyle(
                side: focusSide,
                minimumSize: const WidgetStatePropertyAll(Size.square(44)),
                overlayColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? primary.withValues(alpha: .2)
                      : null,
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style:
                  theme.filledButtonTheme.style?.copyWith(side: focusSide) ??
                  ButtonStyle(side: focusSide),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style:
                  theme.outlinedButtonTheme.style?.copyWith(side: focusSide) ??
                  ButtonStyle(side: focusSide),
            ),
            textButtonTheme: TextButtonThemeData(
              style:
                  theme.textButtonTheme.style?.copyWith(side: focusSide) ??
                  ButtonStyle(side: focusSide),
            ),
            listTileTheme: theme.listTileTheme.copyWith(
              minTileHeight: 56,
              selectedColor: primary,
            ),
          ),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, event) =>
                event is KeyRepeatEvent &&
                    const [
                      LogicalKeyboardKey.select,
                      LogicalKeyboardKey.gameButtonA,
                      LogicalKeyboardKey.enter,
                    ].contains(event.logicalKey)
                ? KeyEventResult.handled
                : KeyEventResult.ignored,
            child: Shortcuts(
              shortcuts: const {
                SingleActivator(
                  LogicalKeyboardKey.select,
                  includeRepeats: false,
                ): _TvActivateIntent(),
                SingleActivator(
                  LogicalKeyboardKey.gameButtonA,
                  includeRepeats: false,
                ): _TvActivateIntent(),
                SingleActivator(
                  LogicalKeyboardKey.enter,
                  includeRepeats: false,
                ): _TvActivateIntent(),
                SingleActivator(
                  LogicalKeyboardKey.arrowUp,
                ): DirectionalFocusIntent(
                  TraversalDirection.up,
                  ignoreTextFields: false,
                ),
                SingleActivator(
                  LogicalKeyboardKey.arrowDown,
                ): DirectionalFocusIntent(
                  TraversalDirection.down,
                  ignoreTextFields: false,
                ),
                SingleActivator(LogicalKeyboardKey.gameButtonB):
                    _TvBackIntent(),
                SingleActivator(LogicalKeyboardKey.escape): _TvBackIntent(),
              },
              child: Actions(
                actions: {
                  _TvActivateIntent: CallbackAction<_TvActivateIntent>(
                    onInvoke: (_) {
                      _activate();
                      return null;
                    },
                  ),
                  _TvBackIntent: CallbackAction<_TvBackIntent>(
                    onInvoke: (_) {
                      _back();
                      return null;
                    },
                  ),
                },
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Same touch target as InkWell; on TV the PRIMARY focused control gets a ring.
/// A nested popup does not highlight its parent subscription header as well.
class TvInkWell extends StatefulWidget {
  const TvInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.autofocus = false,
  });
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final bool autofocus;
  @override
  State<TvInkWell> createState() => _TvInkWellState();
}

class _TvInkWellState extends State<TvInkWell> {
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = TvPresentation.of(context);
    final child = InkWell(
      focusNode: _focus,
      autofocus: widget.autofocus,
      borderRadius: widget.borderRadius,
      onTap: widget.onTap,
      child: widget.child,
    );
    if (!tv) return child;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
        border: Border.all(
          color: _focus.hasPrimaryFocus
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: child,
    );
  }
}

/// Existing settings subpages keep their Navigator/Back behavior on TV.
Widget tvPageFrame(BuildContext context, Widget child) =>
    !TvPresentation.of(context)
    ? child
    : Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: child,
            ),
          ),
        ),
      );
