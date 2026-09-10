import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/service/analytics_service.dart';

void main() {
  late AnalyticsService analytics;
  late List<List<Map<String, dynamic>>> sent;

  setUp(() {
    sent = [];
    analytics = AnalyticsService(sendBatch: (batch) async => sent.add(batch));
  });
  tearDown(() => analytics.onClose());

  bool record(int id, {String source = 'home_feed', int position = 0}) =>
      analytics.recordImpression(
          dealId: id, source: source, position: position);

  testWidgets('claims a deal once across sources before async delivery',
      (tester) async {
    expect(record(42, position: 3), isTrue);
    expect(record(42, source: 'search', position: 8), isFalse);
    expect(record(42, source: 'flash_rail'), isFalse);
    expect(analytics.events.single.properties,
        {'deal_id': 42, 'source': 'home_feed', 'position': 3});
    await tester.pump(const Duration(seconds: 15));
    expect(sent.single.single['name'], 'deal_impression');
    expect(record(42), isFalse);
  });

  testWidgets('flushes at ten immediately and cancels the old deadline',
      (tester) async {
    for (var id = 0; id < 9; id++) {
      record(id);
    }
    expect(sent, isEmpty);
    record(9);
    expect(sent.single.length, 10);
    await tester.pump(const Duration(seconds: 16));
    expect(sent.length, 1);
  });

  testWidgets('15 second deadline belongs to first unsent event',
      (tester) async {
    record(1);
    await tester.pump(const Duration(seconds: 10));
    record(2);
    await tester.pump(const Duration(milliseconds: 4999));
    expect(sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent.single.length, 2);
    record(3);
    await tester.pump(const Duration(milliseconds: 14999));
    expect(sent.length, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(sent.length, 2);
    expect(sent.last.single['properties']['deal_id'], 3);
  });

  testWidgets('new timed batch is independent of an in-flight batch',
      (tester) async {
    analytics.onClose();
    final first = Completer<void>();
    analytics = AnalyticsService(sendBatch: (batch) {
      sent.add(batch);
      return sent.length == 1 ? first.future : Future.value();
    });
    for (var id = 0; id < 10; id++) {
      record(id);
    }
    record(10);
    await tester.pump(const Duration(seconds: 15));
    expect(sent.map((batch) => batch.length), [10, 1]);
    expect(sent.first.length, 10);
    first.complete();
    await tester.pump();
    expect(analytics.events.length, 11);
  });

  testWidgets('second ten-event batch flushes before first request finishes',
      (tester) async {
    analytics.onClose();
    final first = Completer<void>();
    analytics = AnalyticsService(sendBatch: (batch) {
      sent.add(batch);
      return sent.length == 1 ? first.future : Future.value();
    });
    for (var id = 0; id < 20; id++) {
      record(id);
    }
    expect(sent.map((batch) => batch.length), [10, 10]);
    first.complete();
    await tester.pump();
  });

  testWidgets('failed batch retries without duplicate local impressions',
      (tester) async {
    analytics.onClose();
    analytics = AnalyticsService(sendBatch: (batch) async {
      sent.add(batch);
      if (sent.length == 1) throw StateError('delivery failed');
    });
    record(1);
    await tester.pump(const Duration(seconds: 15));
    expect(sent.length, 1);
    expect(record(1, source: 'search'), isFalse);
    record(2);
    await tester.pump(const Duration(seconds: 15));
    expect(sent.length, 3);
    expect(analytics.events.length, 2);
    expect(sent[1], sent[0]);
    expect(sent[2].single['properties']['deal_id'], 2);
  });

  testWidgets('non-impression events keep their existing local behavior',
      (tester) async {
    analytics.logEvent('screen_view', {'screen': '/home'});
    analytics.logEvent('deal_details_view', {'deal_id': 42});
    await tester.pump(const Duration(seconds: 30));
    expect(analytics.events.length, 2);
    expect(sent, isEmpty);
    record(1);
    await tester.pump(const Duration(seconds: 15));
    expect(sent.single.length, 1);
    expect(sent.single.single['name'], 'deal_impression');
  });

  testWidgets('close cancels unsent batch and rejects subsequent recording',
      (tester) async {
    record(1);
    analytics.onClose();
    await tester.pump(const Duration(seconds: 30));
    expect(sent, isEmpty);
    expect(record(2), isFalse);
  });

  testWidgets('close cancels retry and late failure cannot restart timers',
      (tester) async {
    analytics.onClose();
    final inFlight = Completer<void>();
    analytics = AnalyticsService(sendBatch: (batch) {
      sent.add(batch);
      return inFlight.future;
    });
    for (var id = 0; id < 10; id++) {
      record(id);
    }
    analytics.onClose();
    inFlight.completeError(StateError('late failure'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(sent.length, 1);
  });

  testWidgets('close cancels an already scheduled retry', (tester) async {
    analytics.onClose();
    analytics = AnalyticsService(sendBatch: (batch) async {
      sent.add(batch);
      throw StateError('offline');
    });
    record(1);
    await tester.pump(const Duration(seconds: 15));
    analytics.onClose();
    await tester.pump(const Duration(seconds: 30));
    expect(sent.length, 1);
  });

  testWidgets('a new session can record the same deal again', (tester) async {
    record(42);
    analytics.onClose();
    analytics = AnalyticsService(sendBatch: (batch) async => sent.add(batch));
    expect(record(42), isTrue);
    expect(analytics.events.length, 1);
    analytics.onClose();
  });
}
