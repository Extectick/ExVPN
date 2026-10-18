// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Apply only inside a showModalBottomSheet builder. A list at its top hands a
/// downward touch pull to its containing sheet; other scrolling is unchanged.
class ModalSheetScrollScope extends StatelessWidget {
  const ModalSheetScrollScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: const ModalSheetScrollBehavior(),
    child: child,
  );
}

class ModalSheetScrollBehavior extends MaterialScrollBehavior {
  const ModalSheetScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => details.direction == AxisDirection.down
      ? _SheetScrollHandoff(child: child)
      : child;
}

/// Flutter's BottomSheet handles drags that win its gesture arena. A ListView
/// wins that arena over the sheet, so its boundary notifications need an
/// explicit handoff. Only public BottomSheet callbacks/controller are used.
class _SheetScrollHandoff extends StatefulWidget {
  const _SheetScrollHandoff({required this.child});

  final Widget child;

  @override
  State<_SheetScrollHandoff> createState() => _SheetScrollHandoffState();
}

class _SheetScrollHandoffState extends State<_SheetScrollHandoff> {
  int? _touch;
  BottomSheet? _sheet;
  ModalRoute<dynamic>? _route;
  double _height = 1;
  bool _closing = false;

  bool get _dragging => _sheet != null;

  bool _begin(DragUpdateDetails details) {
    final route = ModalRoute.of(context);
    if (route is! ModalBottomSheetRoute || !route.isCurrent) return false;
    BottomSheet? sheet;
    double height = 0;
    context.visitAncestorElements((element) {
      if (element.widget case final BottomSheet candidate) {
        sheet = candidate;
        final render = element.findRenderObject();
        if (render is RenderBox && render.hasSize) height = render.size.height;
        return false;
      }
      return true;
    });
    final controller = sheet?.animationController;
    if (sheet == null ||
        !sheet!.enableDrag ||
        controller == null ||
        controller.status != AnimationStatus.completed ||
        height <= 0) {
      return false;
    }
    _sheet = sheet;
    _route = route;
    _height = height;
    sheet!.onDragStart?.call(
      DragStartDetails(
        sourceTimeStamp: details.sourceTimeStamp,
        globalPosition: details.globalPosition,
        localPosition: details.localPosition,
        kind: PointerDeviceKind.touch,
      ),
    );
    return true;
  }

  void _finish(DragEndDetails details, {bool cancelled = false}) {
    final sheet = _sheet;
    _sheet = null;
    if (sheet == null) return;
    final route = _route;
    _route = null;
    final controller = sheet.animationController!;
    if (!mounted || route?.isCurrent != true || _closing) return;
    final close =
        !cancelled &&
        (controller.value < 0.5 || details.velocity.pixelsPerSecond.dy > 700);
    sheet.onDragEnd?.call(details, isClosing: close);
    if (close) {
      _closing = true;
      // The modal's own callback checks its current route and owns the pop.
      sheet.onClosing();
    } else {
      controller.forward();
    }
  }

  bool _onNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axisDirection != AxisDirection.down ||
        _closing) {
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll < 0 &&
        notification.metrics.extentBefore == 0 &&
        _touch != null) {
      if (_dragging || _begin(notification.dragDetails!)) {
        final controller = _sheet!.animationController!;
        controller.value =
            (controller.value + notification.overscroll / _height).clamp(
              0.0,
              1.0,
            );
      }
    } else if (notification is ScrollUpdateNotification &&
        _dragging &&
        notification.dragDetails != null &&
        (notification.scrollDelta ?? 0) > 0) {
      // Reversing the pull restores the sheet instead of keeping a stale
      // dismissal threshold after the user changes direction.
      final controller = _sheet!.animationController!;
      controller.value =
          (controller.value + notification.scrollDelta! / _height).clamp(
            0.0,
            1.0,
          );
    } else if (notification is ScrollEndNotification && _dragging) {
      _finish(notification.dragDetails ?? DragEndDetails());
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (event.kind == PointerDeviceKind.touch && _touch == null) {
        _touch = event.pointer;
      }
    },
    onPointerUp: (event) {
      if (event.pointer == _touch) _touch = null;
    },
    onPointerCancel: (event) {
      if (event.pointer == _touch) {
        _touch = null;
        _finish(DragEndDetails(), cancelled: true);
      }
    },
    child: NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    ),
  );
}
