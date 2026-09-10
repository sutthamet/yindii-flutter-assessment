import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/feature/home/home_screen.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/model/pickup_window_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

class FixedWindow extends PickupWindowModel {
  FixedWindow(this.today)
      : super(start: DateTime.utc(2026), end: DateTime.utc(2026, 1, 1, 1));
  final bool today;
  @override
  bool get isToday => today;
}

DealModel fixture(int id) => DealModel(
      id: id,
      name: 'Deal $id',
      description: '',
      imageUrl: '',
      originalPrice: 100,
      price: 50,
      currencyCode: 'THB',
      quantityLeft: 5,
      storeId: 1,
      storeName: 'Bakery',
      storeAddress: '',
      lat: 0,
      lng: 0,
      rating: null,
      tags: const [],
      pickupWindow: FixedWindow(id.isEven),
      flashSaleEndsAt: null,
    );

class FeedRepo extends DealRepo {
  FeedRepo() : super(api: FakeApiService());
  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) async =>
      PagedResponseModel(
          items: List.generate(100, fixture), page: 1, totalPages: 1);
  @override
  Future<List<DealModel>> fetchFlashDeals() async => [];
}

void main() {
  late HomeController controller;
  late Duration oldVisibilityInterval;
  setUp(() {
    Get.testMode = true;
    oldVisibilityInterval =
        VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    Get.put(AnalyticsService(sendBatch: (_) async {}));
    controller = Get.put(HomeController(dealRepo: FeedRepo()));
  });
  tearDown(() {
    Get.reset();
    VisibilityDetectorController.instance.updateInterval =
        oldVisibilityInterval;
    Get.testMode = false;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  ListView feed(WidgetTester tester) =>
      tester.widget<SmartRefresher>(find.byType(SmartRefresher)).child!
          as ListView;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    await tester.pump();
  }

  testWidgets('scroll updates chrome thresholds without recreating the feed',
      (tester) async {
    await open(tester);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final refresher =
        tester.widget<SmartRefresher>(find.byType(SmartRefresher));
    controller.scrollController.jumpTo(10);
    await tester.pump();
    expect(tester.widget<Scaffold>(find.byType(Scaffold)), same(scaffold));
    expect(tester.widget<SmartRefresher>(find.byType(SmartRefresher)),
        same(refresher));
    final raisedAppBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(raisedAppBar.elevation, 2);
    for (final offset in [20.0, 30.0, 100.0]) {
      controller.scrollController.jumpTo(offset);
      await tester.pump();
      expect(tester.widget<AppBar>(find.byType(AppBar)), same(raisedAppBar));
    }
    controller.scrollController.jumpTo(900);
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(tester.widget<SmartRefresher>(find.byType(SmartRefresher)),
        same(refresher));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(controller.scrollController.offset, 0);
    expect(tester.widget<AppBar>(find.byType(AppBar)).elevation, 0);
    expect(find.byType(FloatingActionButton), findsNothing);
    await finish(tester);
  });

  testWidgets(
      'feed uses lazy children and reacts to filter, flash and data changes',
      (tester) async {
    await open(tester);
    expect(feed(tester).childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(feed(tester).childrenDelegate.estimatedChildCount, 102);
    expect(find.byType(DealCard).evaluate().length, lessThan(100));
    expect(find.text('Deal 99'), findsNothing);

    await tester.tap(find.byType(FilterChip));
    await tester.pump();
    expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    expect(feed(tester).childrenDelegate.estimatedChildCount, 52);
    expect(
        tester
            .widgetList<DealCard>(find.byType(DealCard))
            .every((c) => c.deal.id.isEven),
        isTrue);

    controller.flashDeals.assignAll([fixture(0)]);
    await tester.pump();
    expect(find.byType(FlashDealsSection), findsOneWidget);
    expect(feed(tester).childrenDelegate.estimatedChildCount, 53);
    controller.deals.clear();
    await tester.pump();
    expect(find.byType(DealCard), findsNothing);
    expect(feed(tester).childrenDelegate.estimatedChildCount, 3);
    controller.flashDeals.clear();
    await tester.pump();
    expect(feed(tester).childrenDelegate.estimatedChildCount, 2);
    controller.deals.add(fixture(102));
    await tester.pump();
    expect(find.text('Deal 102'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
