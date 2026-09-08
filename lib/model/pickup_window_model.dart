import 'package:intl/intl.dart';

/// A store's pickup window. The API sends instants as ISO-8601 UTC strings.
class PickupWindowModel {
  // This catalog serves Asia/Bangkok (UTC+7, no daylight-saving changes).
  static const _marketOffset = Duration(hours: 7);

  final DateTime start;
  final DateTime end;

  const PickupWindowModel({required this.start, required this.end});

  factory PickupWindowModel.fromJson(Map<String, dynamic> json) {
    return PickupWindowModel(
      start: DateTime.parse(json['start'] as String? ?? ''),
      end: DateTime.parse(json['end'] as String? ?? ''),
    );
  }

  /// Human readable label, e.g. "17:30 – 21:00".
  String get label => '${DateFormat('HH:mm').format(_marketTime(start))} – '
      '${DateFormat('HH:mm').format(_marketTime(end))}';

  /// Whether pickup starts today in the store's market timezone.
  bool get isToday => isTodayAt(DateTime.now());

  /// Accept an explicit instant so calendar boundaries can be tested reliably.
  bool isTodayAt(DateTime now) {
    final pickupDay = _marketTime(start);
    final today = _marketTime(now);
    return pickupDay.year == today.year &&
        pickupDay.month == today.month &&
        pickupDay.day == today.day;
  }

  // Shift UTC fields for display/calendar comparison only. Never use this
  // shifted value for duration or open-window comparisons.
  static DateTime _marketTime(DateTime instant) =>
      instant.toUtc().add(_marketOffset);

  /// Whether the store is currently accepting pickups.
  bool get isOpenNow {
    final now = DateTime.now();
    return now.isAfter(start) && now.isBefore(end);
  }

  Duration get untilStart => start.difference(DateTime.now());
}
