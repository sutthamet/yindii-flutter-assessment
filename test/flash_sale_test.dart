import 'support/reservation_test_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/feature/deal/deal_details_screen.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/feature/shared_widget/flash_sale_countdown.dart';
import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/order_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';
import 'support/flash_sale_profile.dart';

DealModel deal(int id, {DateTime? end}) => DealModel.fromJson({
      'id': id,
      'name': 'Flash $id',
      'storeName': 'Bakery',
      'quantityLeft': 10,
      'price': 50,
      'pickupWindow': {
        'start': '2026-09-09T00:00:00Z',
        'end': '2026-09-09T02:00:00Z',
      },
      'flashSaleEndsAt': end?.toIso8601String(),
    });

class ReservationTestClock extends FlashSaleClock {
  ReservationTestClock({required super.now});
  bool get hasActiveListeners => hasListeners;
}

class Orders extends ImmediateOrderRepo {
  Orders({required super.now});
  int calls = 0;
  @override
  Future<OrderModel> checkout(List<CartItemModel> items) {
    calls++;
    throw StateError('Expired-only bag must not reach checkout');
  }
}

class Deals extends DealRepo {
  Deals() : super(api: FakeApiService());
  @override
  Future<DealModel> fetchById(int id) async => deal(id);
}

void main() {
  final start = DateTime.utc(2026, 9, 9);
  late DateTime now;
  late ReservationTestClock clock;
  late CartService cart;
  late Orders orders;
  late List<String> notices;
  late Duration oldVisibilityInterval;

  setUp(() {
    Get.testMode = true;
    oldVisibilityInterval =
        VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    Get.put(AnalyticsService(sendBatch: (_) async {}));
    now = start;
    clock = ReservationTestClock(now: () => now);
    notices = [];
    orders = Orders(now: () => now);
    cart = Get.put(CartService(
        orderRepo: orders, clock: clock, onExpiryNotice: notices.add));
  });

  tearDown(() {
    Get.reset();
    clock.dispose();
    VisibilityDetectorController.instance.updateInterval =
        oldVisibilityInterval;
    Get.testMode = false;
  });

  test('format boundaries, fractional second, long duration and UTC offset',
      () {
    for (final entry in <Duration, String>{
      const Duration(milliseconds: 1): '00:01',
      const Duration(seconds: 59): '00:59',
      const Duration(seconds: 60): '01:00',
      const Duration(seconds: 3599): '59:59',
      const Duration(hours: 1): '01:00:00',
      const Duration(hours: 27, seconds: 1): '27:00:01',
      Duration.zero: 'Expired',
      const Duration(seconds: -1): 'Expired',
    }.entries) {
      expect(flashSaleLabel(start.add(entry.key), start), entry.value);
    }
    expect(flashSaleLabel(DateTime.parse('2026-09-09T07:01:00+07:00'), start),
        '01:00');
    expect(clock.isExpired(null), isFalse);
  });

  testWidgets(
      'bag expires offscreen, removes all quantities once, keeps ordinary deals',
      (tester) async {
    final flash = deal(1, end: start.add(const Duration(seconds: 2)));
    cart.add(flash);
    await tester
        .pump(); // The first hold must settle before increasing quantity.
    cart.add(flash);
    cart.add(deal(2, end: flash.flashSaleEndsAt));
    cart.add(deal(3));
    await tester.pump();
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.itemCount.value, 4);
    now = start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items.map((i) => i.deal.id), [3]);
    expect(cart.itemCount.value, 1);
    expect(cart.total, 50);
    expect(notices.single, contains('Flash 1, Flash 2 expired'));
    // Ordinary deals now also have expiring holds, so the session keeps watching.
    expect(clock.hasActiveListeners, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(notices.length, 1);
    cart.clear();
    await tester.pump();
    expect(clock.hasListeners, isFalse);
  });

  testWidgets('add and checkout check actual time before another tick',
      (tester) async {
    final flash = deal(1, end: start.add(const Duration(seconds: 1)));
    cart.add(flash);
    now = flash.flashSaleEndsAt!;
    await CartController(cartService: cart).checkout();
    expect(orders.calls, 0);
    expect(cart.items, isEmpty);
    expect(cart.add(flash), isFalse);
    expect(cart.items, isEmpty);
    expect(notices.last, contains('cannot be added'));
  });

  testWidgets(
      'resume uses deadline instead of missed ticks; cleanup stops notifications',
      (tester) async {
    cart.add(deal(1, end: start.add(const Duration(minutes: 1))));
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = start.add(const Duration(hours: 2));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(cart.items, isEmpty);
    expect(notices.length, 1);
    cart.add(deal(2, end: now.add(const Duration(seconds: 1))));
    await Get.delete<CartService>(force: true);
    expect(clock.hasListeners, isFalse);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(notices.length, 1);
  });

  testWidgets('checkout requires review if only part of the bag expired',
      (tester) async {
    cart.add(deal(1, end: start.add(const Duration(seconds: 1))));
    cart.add(deal(2));
    now = start.add(const Duration(seconds: 1));
    await CartController(cartService: cart).checkout();
    expect(orders.calls, 0);
    expect(cart.items.single.deal.id, 2);
    expect(notices.length, 1);
    cart.onClose();
    await tester.pump();
  });

  testWidgets(
      'profile fixture mounts 120 countdowns and releases all listeners',
      (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: FlashSaleProfile()));
    expect(find.byType(FlashSaleCountdown), findsNWidgets(120));
    final screen = tester.getRect(find.byType(Scaffold));
    for (final element in find.byType(FlashSaleCountdown).evaluate()) {
      final center = tester.getCenter(find.byWidget(element.widget));
      expect(screen.contains(center), isTrue);
    }
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('01:59'), findsNWidgets(120));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(clock.hasListeners, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '120 mounted countdowns update text without rebuilding parents or expiry shells',
      (tester) async {
    var parentBuilds = 0;
    var shellBuilds = 0;
    final end = start.add(const Duration(seconds: 3));
    await tester.pumpWidget(
        GetMaterialApp(home: Scaffold(body: Builder(builder: (context) {
      parentBuilds++;
      return Wrap(
          children: List.generate(
              120,
              (index) => SizedBox(
                    width: 70,
                    height: 25,
                    child: FlashSaleExpiry(
                      endsAt: end,
                      builder: (context, expired, child) {
                        shellBuilds++;
                        return IgnorePointer(ignoring: expired, child: child);
                      },
                      child: FlashSaleCountdown(endsAt: end),
                    ),
                  )));
    }))));
    expect(find.text('00:03'), findsNWidgets(120));
    final parents = parentBuilds;
    final shells = shellBuilds;
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:02'), findsNWidgets(120));
    expect(parentBuilds, parents);
    expect(shellBuilds, shells);
    now = end;
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Expired'), findsNWidgets(120));
    expect(shellBuilds, shells + 120);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(clock.hasListeners, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('feed and rail retain cards across ticks and disable at expiry',
      (tester) async {
    final flash = deal(1, end: start.add(const Duration(seconds: 2)));
    await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Column(children: [
      DealCard(deal: flash),
      FlashDealsSection(deals: [flash]),
    ])))));
    final cards = tester.widgetList<Card>(find.byType(Card)).toList();
    expect(find.text('00:02'), findsNWidgets(2));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:01'), findsNWidgets(2));
    expect(tester.widgetList<Card>(find.byType(Card)), orderedEquals(cards));
    now = flash.flashSaleEndsAt!;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsNWidgets(2));
    expect(tester.widgetList<Card>(find.byType(Card)), orderedEquals(cards));
    for (final shell in find.byType(FlashSaleExpiry).evaluate()) {
      final pointer = find
          .descendant(
              of: find.byWidget(shell.widget),
              matching: find.byType(IgnorePointer))
          .first;
      expect(tester.widget<IgnorePointer>(pointer).ignoring, isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    expect(clock.hasListeners, isFalse);
  });

  testWidgets(
      'details countdown disables add, removes bag item, and shows real notice',
      (tester) async {
    await Get.delete<CartService>(force: true);
    cart = Get.put(CartService(
        orderRepo: ImmediateOrderRepo(now: () => now), clock: clock));
    final flash = deal(42, end: start.add(const Duration(seconds: 5)));
    Get.routing.args = flash;
    Get.put(DealDetailsController(
        dealRepo: Deals(),
        cartService: cart,
        analytics: AnalyticsService(sendBatch: (_) async {})));
    await tester.pumpWidget(const GetMaterialApp(home: DealDetailsScreen()));
    cart.add(flash);
    await tester.pump();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)), same(scaffold));
    expect(find.text('00:04'), findsOneWidget);
    now = flash.flashSaleEndsAt!;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(cart.items, isEmpty);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton))
            .onPressed,
        isNull);
    expect(find.textContaining('expired and was removed from your bag.'),
        findsOneWidget);
    expect(find.text('Expired'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(clock.hasListeners, isFalse);
  });

  testWidgets(
      'reusing countdown state changes deadline and unsubscribes for ordinary deal',
      (tester) async {
    Future<void> show(DateTime? end) => tester.pumpWidget(GetMaterialApp(
            home: FlashSaleExpiry(
          key: const ValueKey('expiry'),
          endsAt: end,
          builder: (context, expired, _) =>
              Text(expired ? 'disabled' : 'enabled'),
        )));
    await show(start);
    expect(find.text('disabled'), findsOneWidget);
    await show(start.add(const Duration(seconds: 10)));
    expect(find.text('enabled'), findsOneWidget);
    await show(null);
    expect(clock.hasListeners, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
