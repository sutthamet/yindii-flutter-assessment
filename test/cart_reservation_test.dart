import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';
import 'support/reservation_test_support.dart';

void main() {
  final start = DateTime.utc(2026, 9, 10);
  late DateTime now;
  late ControlledOrderRepo repo;
  late CartService cart;
  late FlashSaleClock clock;
  late List<String> notices;
  setUp(() {
    now = start;
    repo = ControlledOrderRepo();
    clock = FlashSaleClock(now: () => now);
    notices = [];
    cart = CartService(
        orderRepo: repo,
        clock: clock,
        onNotice: notices.add,
        onExpiryNotice: notices.add);
  });
  tearDown(() {
    cart.onClose();
    clock.dispose();
  });
  Future<void> held(WidgetTester tester, {int id = 1, DateTime? end}) async {
    cart.add(reservationDeal(id));
    repo.accept(
        repo.holds.length - 1, end ?? now.add(const Duration(minutes: 5)));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    cart.onClose();
    await tester.pump();
  }

  testWidgets('optimistic add precedes Future; success stores the hold',
      (tester) async {
    expect(cart.add(reservationDeal(1)), isTrue);
    expect(cart.itemCount.value, 1);
    expect(cart.total, 50);
    expect(cart.items.single.isPending, isTrue);
    expect(cart.canCheckout, isFalse);
    expect(repo.holds.single.quantity, 1);
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(cart.items.single.reservation!.id, 'r0');
    expect(cart.items.single.isPending, isFalse);
    expect(cart.canCheckout, isTrue);
    await close(tester);
  });

  for (final failure in [
    const ApiException('technical 409', statusCode: 409),
    StateError('network details')
  ]) {
    testWidgets('reserve failure rolls back and does not expose $failure',
        (tester) async {
      cart.add(reservationDeal(1));
      repo.holds.single.result.completeError(failure);
      await tester.pump();
      expect(cart.items, isEmpty);
      expect(cart.itemCount.value, 0);
      expect(notices.single, contains('Please try again'));
      expect(notices.single, isNot(contains('409')));
      expect(notices.single, isNot(contains('network details')));
      await close(tester);
    });
  }

  testWidgets('pending repeats ignored and initial zero-stock add blocked',
      (tester) async {
    expect(cart.add(reservationDeal(1, stock: 0)), isFalse);
    cart.add(reservationDeal(1));
    expect(cart.add(reservationDeal(1)), isFalse);
    cart.decrement(1);
    expect(cart.items.single.quantity, 1);
    expect(repo.holds.length, 1);
    cart.remove(1);
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(repo.releases, ['r0']);
    await close(tester);
  });

  testWidgets('same deal adjustment releases old hold before replacement',
      (tester) async {
    await held(tester);
    repo.controlRelease = true;
    cart.add(reservationDeal(1));
    expect(cart.items.single.quantity, 2);
    expect(cart.items.single.isPending, isTrue);
    expect(repo.releases, ['r0']);
    expect(repo.holds.length, 1);
    repo.releaseResults.single.complete();
    await tester.pump();
    expect(repo.holds.last.quantity, 2);
    repo.accept(1, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(cart.items.single.reservation!.quantity, 2);
    repo.controlRelease = false;
    cart.decrement(1);
    expect(cart.items.single.quantity, 1);
    await tester.pump();
    expect(repo.releases, ['r0', 'r1']);
    expect(repo.holds.last.quantity, 1);
    repo.accept(2, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(cart.items.single.reservation!.id, 'r2');
    cart.decrement(1);
    expect(cart.items, isEmpty);
    expect(repo.releases, ['r0', 'r1', 'r2']);
    await close(tester);
  });

  testWidgets(
      'replacement failure removes line rather than restoring released hold',
      (tester) async {
    await held(tester);
    cart.add(reservationDeal(1));
    await tester.pump();
    repo.holds.last.result
        .completeError(const ApiException('stock', statusCode: 409));
    await tester.pump();
    expect(cart.items, isEmpty);
    expect(repo.releases, ['r0']);
    expect(notices.single, contains('removed'));
    await close(tester);
  });

  testWidgets('remove then re-add: late success cannot overwrite new hold',
      (tester) async {
    cart.add(reservationDeal(1));
    cart.remove(1);
    cart.add(reservationDeal(1));
    repo.accept(1, now.add(const Duration(minutes: 5)));
    await tester.pump();
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(cart.items.single.reservation!.id, 'r1');
    expect(cart.itemCount.value, 1);
    expect(repo.releases, ['r0']);
    expect(notices, isEmpty);
    await close(tester);
  });

  testWidgets('stale failure does not roll back a newer line', (tester) async {
    cart.add(reservationDeal(1));
    cart.remove(1);
    cart.add(reservationDeal(1));
    repo.holds.first.result.completeError(StateError('old failure'));
    await tester.pump();
    expect(cart.items.length, 1);
    expect(notices, isEmpty);
    repo.accept(1, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(cart.items.single.reservation!.id, 'r1');
    await close(tester);
  });

  testWidgets('remove during old-hold release never starts a new reservation',
      (tester) async {
    await held(tester);
    repo.controlRelease = true;
    cart.add(reservationDeal(1));
    cart.remove(1);
    repo.releaseResults.single.complete();
    await tester.pump();
    expect(repo.holds.length, 1);
    expect(cart.items, isEmpty);
    await close(tester);
  });

  testWidgets(
      'release failure blocks replacement, removes line, retries cleanup',
      (tester) async {
    await held(tester);
    repo.controlRelease = true;
    cart.add(reservationDeal(1));
    repo.releaseResults.first.completeError(StateError('release failed'));
    await tester.pump();
    expect(repo.holds.length, 1);
    expect(cart.items, isEmpty);
    expect(notices.any((s) => s.contains('removed')), isTrue);
    repo.releaseResults.last.complete();
    await tester.pump();
    await close(tester);
  });

  testWidgets(
      'remove release retries bounded, does not restore bag or leak timer',
      (tester) async {
    await held(tester);
    repo.controlRelease = true;
    cart.remove(1);
    for (var attempt = 0; attempt < 3; attempt++) {
      repo.releaseResults.last.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
    }
    expect(repo.releases.length, 3);
    expect(cart.items, isEmpty);
    expect(notices.length, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(repo.releases.length, 3);
    await close(tester);
  });

  testWidgets('close cancels cleanup retries; late reserve is released',
      (tester) async {
    await held(tester);
    cart.add(reservationDeal(2));
    repo.controlRelease = true;
    cart.remove(1);
    repo.releaseResults.last.completeError(StateError('offline'));
    await tester.pump();
    cart.onClose();
    repo.controlRelease = false;
    repo.accept(1, now.add(const Duration(minutes: 5)));
    await tester.pump(const Duration(seconds: 30));
    expect(repo.releases, ['r0', 'r1']);
    expect(cart.items.single.reservation, isNull);
    await close(tester);
  });

  testWidgets(
      'absolute reservation expiry removes ordinary line once without renewal',
      (tester) async {
    await held(tester, end: start.add(const Duration(seconds: 2)));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items.length, 1);
    now = start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items, isEmpty);
    expect(repo.releases, ['r0']);
    expect(notices.single, contains('expired'));
    await tester.pump(const Duration(minutes: 10));
    expect(repo.holds.length, 1);
    expect(notices.length, 1);
    await close(tester);
  });

  testWidgets('resume rechecks absolute reservation deadline immediately',
      (tester) async {
    await held(tester);
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = start.add(const Duration(minutes: 6));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(cart.items, isEmpty);
    expect(notices.single, contains('expired'));
    await close(tester);
  });

  testWidgets(
      'quantity edits recheck expiry before a tick and never renew old quantity',
      (tester) async {
    await held(tester, end: start.add(const Duration(seconds: 1)));
    now = start.add(const Duration(seconds: 1));
    expect(cart.add(reservationDeal(1)), isFalse);
    expect(cart.items, isEmpty);
    expect(repo.holds.length, 1);
    expect(notices.single, contains('expired'));
    await close(tester);
  });

  testWidgets(
      'a new ordinary hold keeps clock alive after the flash line expires',
      (tester) async {
    cart.add(
        reservationDeal(1, flashEnd: start.add(const Duration(seconds: 1))));
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    await held(tester, id: 2, end: start.add(const Duration(seconds: 2)));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items.single.deal.id, 2);
    now = start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items, isEmpty);
    expect(repo.releases, ['r0', 'r1']);
    expect(notices.length, 2);
    await close(tester);
  });

  testWidgets('flash expiry during reserve removes line; late hold is released',
      (tester) async {
    cart.add(
        reservationDeal(1, flashEnd: start.add(const Duration(seconds: 1))));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items, isEmpty);
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(repo.releases, ['r0']);
    expect(notices.length, 1);
    await close(tester);
  });

  for (final invalid in ['expired', 'quantity', 'dealId', 'emptyId']) {
    testWidgets('rejects invalid reservation response: $invalid',
        (tester) async {
      cart.add(reservationDeal(1));
      repo.accept(
          0, invalid == 'expired' ? now : now.add(const Duration(minutes: 5)),
          id: invalid == 'emptyId' ? '' : null,
          quantity: invalid == 'quantity' ? 2 : null,
          dealId: invalid == 'dealId' ? 2 : null);
      await tester.pump();
      expect(cart.items, isEmpty);
      expect(cart.canCheckout, isFalse);
      expect(notices.length, 1);
      await close(tester);
    });
  }
}
