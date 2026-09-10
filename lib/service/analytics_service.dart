import 'dart:async';

import 'package:get/get.dart';

import '../util/log_service.dart';

class AnalyticsEvent {
  final String name;
  final Map<String, dynamic> properties;
  final DateTime at;

  AnalyticsEvent(this.name, this.properties) : at = DateTime.now();

  Map<String, dynamic> toJson() => {
        'name': name,
        'properties': properties,
        'at': at.toIso8601String(),
      };
}

/// In-memory analytics sink. Events are visible on the debug screen
/// (overflow menu on Home -> "Analytics debug") and in the console.
///
/// Impressions are claimed once per session and delivered in independent batches.
class AnalyticsService extends GetxService {
  AnalyticsService({required this.sendBatch});

  final Future<void> Function(List<Map<String, dynamic>>) sendBatch;
  final events = <AnalyticsEvent>[].obs;
  final _impressedDeals = <int>{};
  final _pending = <AnalyticsEvent>[];
  final _retries = <Timer>{};
  Timer? _batchTimer;
  bool _closed = false;

  bool hasImpression(int dealId) => _impressedDeals.contains(dealId);

  bool recordImpression({
    required int dealId,
    required String source,
    required int position,
  }) {
    // Claim synchronously, even when two visible instances qualify together.
    if (_closed || !_impressedDeals.add(dealId)) return false;
    final event = AnalyticsEvent('deal_impression', {
      'deal_id': dealId,
      'source': source,
      'position': position,
    });
    events.add(event);
    LogService.log('analytics: ${event.name} ${event.properties}');
    _pending.add(event);
    _batchTimer ??= Timer(const Duration(seconds: 15), _flush);
    if (_pending.length >= 10) _flush();
    return true;
  }

  void _flush() {
    _batchTimer?.cancel();
    _batchTimer = null;
    if (_closed || _pending.isEmpty) return;
    final batch = _pending.map((event) => event.toJson()).toList();
    _pending.clear();
    // A slow previous delivery must not delay a new batch's 10/15 trigger.
    unawaited(_deliver(batch));
  }

  Future<void> _deliver(List<Map<String, dynamic>> batch) async {
    try {
      await sendBatch(batch);
    } catch (error) {
      LogService.error('analytics batch failed; retrying in 15 seconds', error);
      if (_closed) return;
      late final Timer retry;
      retry = Timer(const Duration(seconds: 15), () {
        _retries.remove(retry);
        if (!_closed) unawaited(_deliver(batch));
      });
      _retries.add(retry);
    }
  }

  @override
  void onClose() {
    _closed = true;
    _batchTimer?.cancel();
    for (final timer in _retries) {
      timer.cancel();
    }
    _retries.clear();
    _pending.clear();
    super.onClose();
  }

  void logEvent(String name, [Map<String, dynamic> properties = const {}]) {
    final event = AnalyticsEvent(name, properties);
    events.add(event);
    LogService.log('analytics: $name $properties');
  }
}
