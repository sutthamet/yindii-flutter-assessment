import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/order/widget/pickup_countdown.dart';

void main() {
  testWidgets('countdown cancels its timer when disposed before the first tick',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PickupCountdown(pickupStart: DateTime.utc(2100)),
    ));
    expect(find.byType(PickupCountdown), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    // The test binding also rejects periodic timers left pending at teardown.
  });

  testWidgets('mounted countdown still rebuilds on ticks and cleans up each time',
      (tester) async {
    for (var cycle = 0; cycle < 2; cycle++) {
      await tester.pumpWidget(MaterialApp(
        home: PickupCountdown(pickupStart: DateTime.utc(2100)),
      ));
      final label = find.descendant(
        of: find.byType(PickupCountdown), matching: find.byType(Text));
      final beforeTick = tester.widget<Text>(label);
      // The build creates a new Text widget on each tick, even if the wall
      // clock has not advanced. No real-time sleep or clock injection needed.
      await tester.pump(const Duration(seconds: 1));
      expect(identical(tester.widget<Text>(label), beforeTick), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    }
  });
}
