import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/model/pickup_window_model.dart';

void main() {
  for (final example in [
    ['2026-01-01T23:00:00Z', '2026-01-02T02:30:00Z', '06:00 – 09:30'],
    ['2026-01-02T15:00:00Z', '2026-01-02T18:00:00Z', '22:00 – 01:00'],
    ['2026-12-31T17:00:00Z', '2026-12-31T18:30:00Z', '00:00 – 01:30'],
  ]) {
    test('market label for ${example[0]} is ${example[2]}', () {
      final window = PickupWindowModel.fromJson({
        'start': example[0],
        'end': example[1],
      });
      expect(window.label, example[2]);
      expect(window.start, DateTime.parse(example[0]));
      expect(window.end, DateTime.parse(example[1]));
      expect(window.start.isUtc, isTrue);
    });
  }
}
