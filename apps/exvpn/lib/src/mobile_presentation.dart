// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum MobileFormFactor { phone, tablet }

/// Classify the display, not a rotated or letterboxed application viewport.
MobileFormFactor mobileFormFactor(Size displaySize, double pixelRatio) =>
    displaySize.shortestSide / pixelRatio >= 600
    ? MobileFormFactor.tablet
    : MobileFormFactor.phone;

class MobilePresentation extends InheritedWidget {
  const MobilePresentation({
    super.key,
    required this.tablet,
    required super.child,
  });

  final bool tablet;

  static bool isTabletOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MobilePresentation>()
          ?.tablet ??
      false;

  @override
  bool updateShouldNotify(MobilePresentation oldWidget) =>
      tablet != oldWidget.tablet;
}

/// Android phones stay upright; tablets and televisions retain OS orientation.
class AndroidMobilePresentation extends StatefulWidget {
  const AndroidMobilePresentation({
    super.key,
    required this.television,
    required this.child,
  });

  final bool television;
  final Widget child;

  @override
  State<AndroidMobilePresentation> createState() =>
      _AndroidMobilePresentationState();
}

class _AndroidMobilePresentationState extends State<AndroidMobilePresentation>
    with WidgetsBindingObserver {
  ui.FlutterView? _view;
  bool _tablet = false;
  bool? _portraitRequested;

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.maybeOf(context);
    _tablet = _isTabletDisplay;
    _applyOrientation();
  }

  bool get _isTabletDisplay {
    final display = _view?.display;
    return _android &&
        !widget.television &&
        display != null &&
        mobileFormFactor(display.size, display.devicePixelRatio) ==
            MobileFormFactor.tablet;
  }

  @override
  void didChangeMetrics() {
    final tablet = _isTabletDisplay;
    if (tablet != _tablet) setState(() => _tablet = tablet);
    _applyOrientation();
  }

  @override
  void didUpdateWidget(AndroidMobilePresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tablet = _isTabletDisplay;
    _applyOrientation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      didChangeMetrics();
      _applyOrientation(force: true);
    }
  }

  void _applyOrientation({bool force = false}) {
    if (!_android || _view == null) return;
    final portrait = !_tablet && !widget.television;
    if (!force && _portraitRequested == portrait) return;
    _portraitRequested = portrait;
    unawaited(_requestOrientation(portrait));
  }

  Future<void> _requestOrientation(bool portrait) async {
    try {
      await SystemChrome.setPreferredOrientations(
        portrait ? const [DeviceOrientation.portraitUp] : const [],
      );
    } on PlatformException {
      _portraitRequested = null;
    } on MissingPluginException {
      _portraitRequested = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      MobilePresentation(tablet: _tablet, child: widget.child);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _view = null;
    super.dispose();
  }
}
