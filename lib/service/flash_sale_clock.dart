import 'dart:async';

import 'package:flutter/widgets.dart';

/// Shared by countdowns and the bag. No timer runs without listeners.
class FlashSaleClock extends ChangeNotifier with WidgetsBindingObserver {
  FlashSaleClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Timer? _timer;
  final _registrations = <VoidCallback>[];

  void _startTimer() {
    _timer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  DateTime get now => _now();
  bool isExpired(DateTime? end) => end != null && !end.isAfter(now);

  @override
  void addListener(VoidCallback listener) {
    final wasEmpty = _registrations.isEmpty;
    _registrations.add(listener);
    super.addListener(listener);
    if (wasEmpty) {
      WidgetsBinding.instance.addObserver(this);
      _startTimer();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _registrations.remove(listener);
    // ChangeNotifier defers its own count update during notification.
    if (_registrations.isEmpty) _stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifyListeners();
      if (_registrations.isNotEmpty) _startTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void dispose() {
    _stop();
    _registrations.clear();
    super.dispose();
  }
}

String flashSaleLabel(DateTime end, DateTime now) {
  final micros = end.difference(now).inMicroseconds;
  if (micros <= 0) return 'Expired';
  // Round up so a still-valid deal never displays 00:00.
  final seconds = (micros / Duration.microsecondsPerSecond).ceil();
  String pad(int value) => value.toString().padLeft(2, '0');
  final minutes = pad((seconds ~/ 60) % 60);
  final remainder = pad(seconds % 60);
  return seconds >= 3600
      ? '${pad(seconds ~/ 3600)}:$minutes:$remainder'
      : '$minutes:$remainder';
}
