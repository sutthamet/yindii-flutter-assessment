import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/cart/cart_screen.dart';
import 'package:rescu/feature/cart/widget/reservation_countdown.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/flash_sale_clock.dart';
import 'support/reservation_test_support.dart';

class ObservedClock extends FlashSaleClock {
  ObservedClock({required super.now});
  int listeners = 0;
  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

void main() {
  final start = DateTime.utc(2026, 9, 10);
  late DateTime now;
  late ObservedClock clock;
  late ControlledOrderRepo repo;
  late CartService cart;
  late List<String> notices;
  setUp(() {
    Get.testMode = true;
    now = start;
    notices = [];
    repo = ControlledOrderRepo();
    clock = ObservedClock(now: () => now);
    cart = Get.put(CartService(
        orderRepo: repo,
        clock: clock,
        onNotice: notices.add,
        onExpiryNotice: notices.add));
    Get.put(CartController(cartService: cart));
  });
  tearDown(() {
    Get.reset();
    clock.dispose();
    Get.testMode = false;
  });
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    cart.onClose();
    await tester.pump();
    expect(clock.listeners, 0);
  }

  testWidgets('bag renders optimistic pending state then reserved countdown',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GetMaterialApp(home: CartScreen()));
    cart.add(reservationDeal(1));
    await tester.pump();
    expect(find.text('Deal 1'), findsOneWidget);
    expect(find.text('Reserving…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(find.text('Reserved for 05:00'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    final card = tester.widget<Card>(find.byType(Card));
    final list = tester.widget<ListView>(find.byType(ListView));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Reserved for 04:59'), findsOneWidget);
    expect(tester.widget<Card>(find.byType(Card)), same(card));
    expect(tester.widget<ListView>(find.byType(ListView)), same(list));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('409 removes optimistic card and reports understandable notice',
      (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: CartScreen()));
    cart.add(reservationDeal(1));
    await tester.pump();
    repo.holds.single.result
        .completeError(const ApiException('technical 409', statusCode: 409));
    await tester.pump();
    expect(find.text('Your bag is empty'), findsOneWidget);
    expect(notices.single, contains('Please try again'));
    expect(notices.single, isNot(contains('409')));
    await finish(tester);
  });

  testWidgets(
      'remove button works during reserve and late result cannot reappear',
      (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: CartScreen()));
    cart.add(reservationDeal(1));
    await tester.pump();
    await tester.tap(find.byTooltip('Remove item'));
    await tester.pump();
    repo.accept(0, now.add(const Duration(minutes: 5)));
    await tester.pump();
    expect(find.text('Your bag is empty'), findsOneWidget);
    expect(repo.releases, ['r0']);
    await finish(tester);
  });

  testWidgets('expired bag during checkout retains visible processing state',
      (tester) async {
    cart.add(reservationDeal(1));
    repo.accept(0, start.add(const Duration(seconds: 1)));
    await tester.pump();
    await tester.pumpWidget(const GetMaterialApp(home: CartScreen()));
    await tester.tap(find.text('Checkout'));
    await tester.pump();
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Confirming your order…'), findsOneWidget);
    expect(repo.releases, isEmpty);
    repo.checkoutResults.single.complete(reservationOrder());
    await tester.pump();
    expect(find.text('Your bag is empty'), findsOneWidget);
    expect(notices.last, contains('confirmed'));
    await finish(tester);
  });

  testWidgets(
      '120 reservation texts share a clock without rebuilding parent cards',
      (tester) async {
    var parentBuilds = 0;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (_) {
      parentBuilds++;
      return Wrap(
          children: List.generate(
              120,
              (_) => SizedBox(
                  width: 100,
                  height: 25,
                  child: ReservationCountdown(
                      clock: clock,
                      expiresAt: start.add(const Duration(seconds: 2))))));
    })));
    expect(clock.listeners, 120);
    expect(find.text('Reserved for 00:02'), findsNWidgets(120));
    now = start.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Reserved for 00:01'), findsNWidgets(120));
    expect(parentBuilds, 1);
    now = start.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Hold expired'), findsNWidgets(120));
    expect(parentBuilds, 1);
    await finish(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reused countdown reads new expiry and unsubscribes on disposal',
      (tester) async {
    Future<void> show(DateTime end) => tester.pumpWidget(MaterialApp(
        home: ReservationCountdown(
            key: const ValueKey('hold'), clock: clock, expiresAt: end)));
    await show(start.add(const Duration(seconds: 1)));
    await show(start.add(const Duration(minutes: 2)));
    expect(find.text('Reserved for 02:00'), findsOneWidget);
    expect(clock.listeners, 1);
    clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = start.add(const Duration(minutes: 3));
    clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Hold expired'), findsOneWidget);
    await finish(tester);
  });
}
