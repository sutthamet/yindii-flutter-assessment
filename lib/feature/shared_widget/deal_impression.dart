import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../service/analytics_service.dart';

final impressionRouteObserver = RouteObserver<ModalRoute<dynamic>>();

/// Measures a continuous foreground exposure without rebuilding on scroll.
class DealImpression extends StatefulWidget {
  const DealImpression({
    super.key,
    required this.dealId,
    required this.source,
    required this.position,
    required this.child,
  });

  final int dealId;
  final String source;
  final int position;
  final Widget child;

  @override
  State<DealImpression> createState() => _DealImpressionState();
}

class _DealImpressionState extends State<DealImpression>
    with WidgetsBindingObserver, RouteAware {
  late final AnalyticsService _analytics;
  Key _detectorKey = UniqueKey();
  ModalRoute<dynamic>? _route;
  Timer? _dwellTimer;
  bool _visible = false;
  bool _routeVisible = true;
  bool _foreground = true;
  int _window = 0;

  bool get _active =>
      _foreground && _routeVisible && (_route?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    _analytics = Get.find<AnalyticsService>();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      impressionRouteObserver.unsubscribe(this);
      _route = route;
      _routeVisible = route?.isCurrent ?? true;
      if (route != null) impressionRouteObserver.subscribe(this, route);
    }
  }

  void _cancelWindow() {
    _window++;
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _visible = false;
  }

  void _freshGeometry() {
    _cancelWindow();
    VisibilityDetectorController.instance.forget(_detectorKey);
    // Re-measure on the next frame; never reuse pre-background visibility.
    _detectorKey = UniqueKey();
  }

  void _visibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    if (!_active || info.visibleFraction < 0.5) {
      if (_visible || _dwellTimer != null) _cancelWindow();
      return;
    }
    _visible = true;
    if (_dwellTimer != null || _analytics.hasImpression(widget.dealId)) return;
    final window = _window;
    _dwellTimer = Timer(const Duration(seconds: 1), () {
      // Process any pending geometry before accepting the exposure.
      VisibilityDetectorController.instance.notifyNow();
      if (!mounted || window != _window || !_active || !_visible) return;
      _dwellTimer = null;
      _analytics.recordImpression(
        dealId: widget.dealId,
        source: widget.source,
        position: widget.position,
      );
    });
  }

  @override
  void didUpdateWidget(DealImpression oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dealId != widget.dealId ||
        oldWidget.source != widget.source ||
        oldWidget.position != widget.position) {
      _freshGeometry();
    }
  }

  void _routeChanged(bool visible) {
    if (_routeVisible == visible) return;
    _routeVisible = visible;
    setState(_freshGeometry);
  }

  @override
  void didPushNext() => _routeChanged(false);

  @override
  void didPopNext() => _routeChanged(true);

  @override
  void didPop() => _routeChanged(false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    setState(_freshGeometry);
  }

  @override
  void dispose() {
    _cancelWindow();
    impressionRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    VisibilityDetectorController.instance.forget(_detectorKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VisibilityDetector(
        key: _detectorKey,
        onVisibilityChanged: _visibilityChanged,
        child: widget.child,
      );
}
