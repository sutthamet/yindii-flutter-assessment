import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/pickup_window_model.dart';

PickupWindowModel window(String start) => PickupWindowModel.fromJson({
      'start': start,
      'end':
          DateTime.parse(start).add(const Duration(hours: 2)).toIso8601String(),
    });

void main() {
  test('early morning pickup and today use Bangkok calendar dates', () {
    final pickup = window('2026-01-01T23:00:00Z'); // Jan 2, 06:00 Bangkok
    expect(pickup.isTodayAt(DateTime.parse('2026-01-02T00:00:00Z')), isTrue);
    expect(pickup.isTodayAt(DateTime.parse('2026-01-01T16:59:59Z')), isFalse);
    expect(pickup.isTodayAt(DateTime.parse('2026-01-01T17:00:00Z')), isTrue);
  });

  test('the same day number in different months or years is not today', () {
    final pickup = window('2026-01-02T01:00:00Z');
    expect(pickup.isTodayAt(DateTime.utc(2026, 2, 2)), isFalse);
    expect(pickup.isTodayAt(DateTime.utc(2027, 1, 2)), isFalse);
  });

  test('year and leap-day boundaries use the complete market date', () {
    expect(
        window('2026-12-31T23:00:00Z')
            .isTodayAt(DateTime.parse('2027-01-01T00:00:00Z')),
        isTrue);
    expect(
        window('2028-02-28T23:00:00Z')
            .isTodayAt(DateTime.parse('2028-02-29T00:00:00Z')),
        isTrue);
    expect(
        window('2028-02-29T23:00:00Z')
            .isTodayAt(DateTime.parse('2028-03-01T00:00:00Z')),
        isTrue);
  });

  test('explicit offsets represent the same instant and market day', () {
    final utc = window('2026-01-01T23:00:00Z');
    final offset = window('2026-01-02T06:00:00+07:00');
    final now = DateTime.parse('2026-01-02T07:00:00+07:00');
    expect(offset.start, utc.start);
    expect(offset.label, utc.label);
    expect(offset.isTodayAt(now), utc.isTodayAt(now));
  });

  test('today means start date, not any overlap with an overnight window', () {
    final overnight = window('2026-01-01T16:30:00Z'); // 23:30 to 01:30
    expect(
        overnight.isTodayAt(DateTime.parse('2026-01-01T17:30:00Z')), isFalse);
  });

  test('parsed deals filter by the correct day without changing UTC instants',
      () {
    final deals = [
      DealModel.fromJson({
        'id': 1,
        'pickupWindow': {
          'start': '2026-01-01T23:00:00Z',
          'end': '2026-01-02T02:30:00Z',
        }
      }),
      DealModel.fromJson({
        'id': 2,
        'pickupWindow': {
          'start': '2026-01-02T23:00:00Z',
          'end': '2026-01-03T02:30:00Z',
        }
      }),
    ];
    final now = DateTime.utc(2026, 1, 2);
    expect(deals.where((d) => d.pickupWindow.isTodayAt(now)).map((d) => d.id),
        [1]);
    expect(deals.first.pickupWindow.start.isUtc, isTrue);
  });
}
