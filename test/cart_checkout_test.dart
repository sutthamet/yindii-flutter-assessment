import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/reservation_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';
import 'support/reservation_test_support.dart';

class CheckoutApi extends FakeApiService {
  List<Map<String, dynamic>>? payload;
  @override
  Future<Map<String, dynamic>> checkout(
      List<Map<String, dynamic>> items) async {
    payload = items;
    return {
      'id': 123,
      'pickupStart': '2026-09-10T00:00:00Z',
      'pickupEnd': '2026-09-10T02:00:00Z'
    };
  }
}

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
    notices = [];
    clock = FlashSaleClock(now: () => now);
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
  Future<void> held(WidgetTester tester, int id,
      {DateTime? end, DateTime? flashEnd}) async {
    cart.add(reservationDeal(id, flashEnd: flashEnd));
    repo.accept(
        repo.holds.length - 1, end ?? now.add(const Duration(minutes: 5)));
    await tester.pump();
  }

  for (final invalid in [
    'pending',
    'missing',
    'expired',
    'quantity',
    'dealId'
  ]) {
    testWidgets('checkout blocks $invalid line', (tester) async {
      if (invalid == 'pending') {
        cart.add(reservationDeal(1));
      } else {
        await held(tester, 1);
        final line = cart.items.single;
        if (invalid == 'missing') line.reservation = null;
        if (invalid == 'expired') now = start.add(const Duration(minutes: 5));
        if (invalid == 'quantity') line.quantity = 2;
        if (invalid == 'dealId') {
          line.reservation = ReservationModel(
              id: 'bad',
              dealId: 2,
              quantity: 1,
              expiresAt: now.add(const Duration(minutes: 5)));
        }
      }
      await cart.checkout();
      expect(repo.checkouts, isEmpty);
      expect(cart.isCheckingOut.value, isFalse);
      cart.onClose();
      await tester.pump();
    });
  }

  testWidgets(
      'checkout snapshot immutable from cart edits; IDs and quantities retained',
      (tester) async {
    await held(tester, 1);
    await held(tester, 2);
    final firstLine = cart.items.first;
    final future = cart.checkout();
    expect(repo.checkouts.single.map((i) => i.reservation!.id), ['r0', 'r1']);
    expect(identical(firstLine, repo.checkouts.single.first), isFalse);
    expect(cart.add(reservationDeal(3)), isFalse);
    cart.decrement(1);
    cart.remove(1);
    cart.clear();
    expect(cart.items.length, 2);
    expect(repo.checkouts.single.map((i) => i.quantity), [1, 1]);
    repo.checkoutResults.single.complete(reservationOrder());
    expect((await future)!.id, 123);
    expect(cart.items, isEmpty);
    expect(cart.isCheckingOut.value, isFalse);
    expect(repo.releases, containsAll(['r0', 'r1']));
    expect(notices.single, contains('confirmed'));
    await tester.pump();
  });

  testWidgets('double checkout prevented across replaced cart controllers',
      (tester) async {
    await held(tester, 1);
    final first = CartController(cartService: cart);
    final future = first.checkout();
    first.onClose();
    await CartController(cartService: cart).checkout();
    expect(repo.checkouts.length, 1);
    repo.checkoutResults.single.complete(reservationOrder());
    await future;
    expect(notices.single, contains('confirmed'));
    await tester.pump();
  });

  testWidgets(
      'checkout after quantity replacement sends only the new matching hold',
      (tester) async {
    await held(tester, 1);
    cart.add(reservationDeal(1));
    await tester.pump();
    await cart.checkout();
    expect(repo.checkouts, isEmpty);
    repo.accept(1, now.add(const Duration(minutes: 5)));
    await tester.pump();
    final future = cart.checkout();
    expect(repo.checkouts.single.single.quantity, 2);
    expect(repo.checkouts.single.single.reservation!.id, 'r1');
    expect(repo.checkouts.single.single.reservation!.quantity, 2);
    repo.checkoutResults.single.complete(reservationOrder());
    await future;
    await tester.pump();
  });

  for (final flash in [false, true]) {
    testWidgets(
        '${flash ? 'flash' : 'reservation'} expiry in checkout removes UI but defers release until success',
        (tester) async {
      final end = start.add(const Duration(seconds: 1));
      await held(tester, 1,
          end: flash ? null : end, flashEnd: flash ? end : null);
      final future = cart.checkout();
      now = end;
      await tester.pump(const Duration(seconds: 1));
      expect(cart.items, isEmpty);
      expect(cart.isCheckingOut.value, isTrue);
      expect(repo.releases, isEmpty);
      expect(repo.checkouts.single.single.reservation!.id, 'r0');
      repo.checkoutResults.single.complete(reservationOrder());
      await future;
      expect(repo.releases, ['r0']);
      expect(notices.last, contains('confirmed'));
      await tester.pump();
    });
  }

  testWidgets(
      '410 discards submitted holds without guessing the failing line or auto-resubmitting',
      (tester) async {
    await held(tester, 1);
    await held(tester, 2);
    final future = cart.checkout();
    repo.checkoutResults.single.completeError(
        const ApiException('Unknown reservation 410', statusCode: 410));
    await future;
    expect(cart.items, isEmpty);
    expect(repo.releases, ['r0', 'r1']);
    expect(notices.single, contains('add the items again'));
    expect(notices.single, isNot(contains('410')));
    expect(repo.checkouts.length, 1);
    expect(repo.holds.length, 2);
    expect(cart.isCheckingOut.value, isFalse);
    await tester.pump();
  });

  for (final error in [
    const ApiException('backend 502', statusCode: 502),
    StateError('unexpected')
  ]) {
    testWidgets('non-410 $error keeps only valid holds and unlocks checkout',
        (tester) async {
      await held(tester, 1, end: start.add(const Duration(seconds: 1)));
      await held(tester, 2);
      final future = cart.checkout();
      now = start.add(const Duration(seconds: 2));
      repo.checkoutResults.single.completeError(error);
      await future;
      expect(cart.items.single.deal.id, 2);
      expect(cart.canCheckout, isTrue);
      expect(repo.releases, ['r0']);
      expect(notices.last, isNot(contains('502')));
      cart.onClose();
      await tester.pump();
    });
  }

  testWidgets(
      'close during checkout defers release; late result cannot notify closed service',
      (tester) async {
    await held(tester, 1);
    final future = cart.checkout();
    cart.onClose();
    expect(repo.releases, isEmpty);
    repo.checkoutResults.single.completeError(StateError('late'));
    await future;
    expect(repo.releases, ['r0']);
    expect(notices, isEmpty);
    await tester.pump();
  });

  test('existing repository serializes dealId, quantity and reservationId',
      () async {
    final api = CheckoutApi();
    await OrderRepo(api: api).checkout([
      CartItemModel(
          deal: reservationDeal(42),
          quantity: 2,
          reservation: ReservationModel(
              id: 'hold42',
              dealId: 42,
              quantity: 2,
              expiresAt: start.add(const Duration(minutes: 5))))
    ]);
    expect(api.payload, [
      {'dealId': 42, 'quantity': 2, 'reservationId': 'hold42'}
    ]);
  });
}
