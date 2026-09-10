import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/analytics_debug/analytics_debug_screen.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/feature/home/home_screen.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/search/search_deals_controller.dart';
import 'package:rescu/feature/search/search_screen.dart';
import 'package:rescu/feature/shared_widget/deal_impression.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

DealModel deal(int id) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'quantityLeft': 2,
      'pickupWindow': {
        'start': '2026-09-10T00:00:00Z',
        'end': '2026-09-10T01:00:00Z',
      },
    });

class FeedRepo extends DealRepo {
  FeedRepo() : super(api: FakeApiService());
  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) async =>
      PagedResponseModel(items: [deal(1), deal(2)], page: 1, totalPages: 1);
  @override
  Future<List<DealModel>> fetchFlashDeals() async => [deal(10), deal(11)];
}

void main() {
  late AnalyticsService analytics;
  late Duration oldInterval;

  setUp(() {
    Get.testMode = true;
    oldInterval = VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    analytics = Get.put(AnalyticsService(sendBatch: (_) async {}));
    Get.put(CartService());
  });
  tearDown(() {
    Get.reset();
    Get.testMode = false;
    VisibilityDetectorController.instance.updateInterval = oldInterval;
  });

  Widget exposure({
    double height = 100,
    int id = 42,
    String source = 'home_feed',
    int position = 0,
    Widget child = const SizedBox(width: 100, height: 100),
  }) =>
      Align(
        alignment: Alignment.topLeft,
        child: ClipRect(
          child: SizedBox(
            width: 100,
            height: height,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 100,
              maxHeight: 100,
              minWidth: 100,
              maxWidth: 100,
              child: DealImpression(
                dealId: id,
                source: source,
                position: position,
                child: child,
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester, Widget body) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [impressionRouteObserver],
      home: Scaffold(body: body),
    ));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    analytics.onClose();
    await tester.pump();
  }

  testWidgets(
      'exactly 50 percent: 999 ms is insufficient; one second qualifies',
      (tester) async {
    await open(tester, exposure(height: 50));
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.single.properties,
        {'deal_id': 42, 'source': 'home_feed', 'position': 0});
    await close(tester);
  });

  testWidgets('49 percent never qualifies', (tester) async {
    await open(tester, exposure(height: 49));
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    await close(tester);
  });

  testWidgets(
      'a brief dip below 50 percent cancels and restarts the full second',
      (tester) async {
    await open(tester, exposure(height: 50));
    await tester.pump(const Duration(milliseconds: 800));
    await open(tester, exposure(height: 49));
    await tester.pump(const Duration(milliseconds: 50));
    await open(tester, exposure(height: 60));
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await close(tester);
  });

  testWidgets('changes above threshold do not restart the visibility window',
      (tester) async {
    await open(tester, exposure(height: 50));
    await tester.pump(const Duration(milliseconds: 800));
    await open(tester, exposure(height: 70));
    await tester.pump(const Duration(milliseconds: 200));
    expect(analytics.events.length, 1);
    await close(tester);
  });

  for (final attribute in ['dealId', 'source', 'position']) {
    testWidgets('$attribute change resets an in-progress attribution window',
        (tester) async {
      await open(tester, exposure());
      await tester.pump(const Duration(milliseconds: 800));
      await open(
          tester,
          exposure(
            id: attribute == 'dealId' ? 43 : 42,
            source: attribute == 'source' ? 'search' : 'home_feed',
            position: attribute == 'position' ? 2 : 0,
          ));
      await tester.pump(const Duration(milliseconds: 999));
      expect(analytics.events, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(analytics.events.single.properties, {
        'deal_id': attribute == 'dealId' ? 43 : 42,
        'source': attribute == 'source' ? 'search' : 'home_feed',
        'position': attribute == 'position' ? 2 : 0,
      });
      await close(tester);
    });
  }

  testWidgets('simultaneous sources and later revisits record one deal once',
      (tester) async {
    await open(
        tester,
        Row(children: [
          SizedBox(width: 100, child: exposure(source: 'flash_rail')),
          SizedBox(width: 100, child: exposure(source: 'home_feed')),
        ]));
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 1);
    expect(analytics.events.single.properties['deal_id'], 42);
    await open(tester, exposure(source: 'search', position: 5));
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events.length, 1);
    await close(tester);
  });

  testWidgets('unmount cancels a pending window', (tester) async {
    await open(tester, exposure());
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    await close(tester);
  });

  testWidgets('background interrupts exposure; resume starts a fresh window',
      (tester) async {
    await open(tester, exposure());
    await tester.pump(const Duration(milliseconds: 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 5));
    expect(analytics.events, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await close(tester);
  });

  testWidgets('covering the route interrupts exposure, including a dialog',
      (tester) async {
    await open(tester, exposure());
    await tester.pump(const Duration(milliseconds: 800));
    final context = tester.element(find.byType(DealImpression));
    showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Cover')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    // Pop animation time may contribute, so assert no event before a full second
    // and finish the new interval with a conservative additional second.
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 1);
    await close(tester);
  });

  testWidgets(
      'route navigation resets dwell and debug screen displays the event',
      (tester) async {
    await open(tester, exposure(position: 4));
    await tester.pump(const Duration(milliseconds: 800));
    final navigator = Navigator.of(tester.element(find.byType(DealImpression)));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another page'))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 1);
    navigator.push(
        MaterialPageRoute<void>(builder: (_) => const AnalyticsDebugScreen()));
    await tester.pumpAndSettle();
    expect(find.text('deal_impression'), findsOneWidget);
    expect(find.text('{deal_id: 42, source: home_feed, position: 4}'),
        findsOneWidget);
    await close(tester);
  });

  testWidgets('120 exposures do not rebuild their child or root on callbacks',
      (tester) async {
    var rootBuilds = 0;
    var childBuilds = 0;
    await open(tester, Builder(builder: (_) {
      rootBuilds++;
      return Column(
        children: List.generate(
            20,
            (row) => Expanded(
                    child: Row(
                  children: List.generate(
                      6,
                      (column) => Expanded(
                            child: DealImpression(
                              dealId: row * 6 + column,
                              source: 'home_feed',
                              position: row * 6 + column,
                              child: Builder(builder: (_) {
                                childBuilds++;
                                return const SizedBox.expand();
                              }),
                            ),
                          )),
                ))),
      );
    }));
    final rootBefore = rootBuilds;
    final childrenBefore = childBuilds;
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 120);
    expect(rootBuilds, rootBefore);
    expect(childBuilds, childrenBefore);
    await close(tester);
  });

  testWidgets('home positions exclude headers; rail uses its own indices',
      (tester) async {
    Get.put(HomeController(dealRepo: FeedRepo()));
    await open(tester, const HomeScreen());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final wrappers =
        tester.widgetList<DealImpression>(find.byType(DealImpression));
    expect(
        wrappers.where((w) => w.source == 'flash_rail').map((w) => w.position),
        [0, 1]);
    expect(wrappers.where((w) => w.source == 'home_feed').first.position, 0);
    await tester.pump(const Duration(seconds: 1));
    final home =
        analytics.events.where((e) => e.properties['source'] == 'home_feed');
    expect(home.first.properties,
        {'deal_id': 1, 'source': 'home_feed', 'position': 0});
    expect(analytics.events.any((e) => e.properties['source'] == 'flash_rail'),
        isTrue);
    await close(tester);
  });

  testWidgets(
      'search and rail emit correct deal properties and zero-based positions',
      (tester) async {
    final search = Get.put(SearchDealsController(dealRepo: FeedRepo()));
    search.results.assignAll([deal(7), deal(8)]);
    search.hasSearched.value = true;
    await open(tester, const SearchScreen());
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.first.properties,
        {'deal_id': 7, 'source': 'search', 'position': 0});
    expect(
        tester
            .widgetList<DealImpression>(find.byType(DealImpression))
            .map((w) => w.position),
        [0, 1]);
    await open(tester, FlashDealsSection(deals: [deal(7), deal(9)]));
    await tester.pump(const Duration(seconds: 1));
    expect(
        analytics.events.where((e) => e.properties['deal_id'] == 7).length, 1);
    expect(
        analytics.events
            .singleWhere((e) => e.properties['deal_id'] == 9)
            .properties,
        {'deal_id': 9, 'source': 'flash_rail', 'position': 1});
    await close(tester);
  });
}
