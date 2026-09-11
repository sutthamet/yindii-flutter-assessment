import 'support/reservation_test_support.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/routes/routes.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';

DealModel fixture(int id) => DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'storeName': 'Test bakery',
      'description': 'Fresh bread',
      'price': 50,
      'quantityLeft': 7,
      'pickupWindow': {
        'start': '2026-01-01T23:00:00Z',
        'end': '2026-01-02T02:30:00Z',
      },
    });

class ControlledRepo extends DealRepo {
  ControlledRepo() : super(api: FakeApiService());
  final ids = <int>[];
  final pending = <Completer<DealModel>>[];

  @override
  Future<DealModel> fetchById(int id) {
    ids.add(id);
    final request = Completer<DealModel>();
    pending.add(request);
    return request.future;
  }
}

void main() {
  late ControlledRepo repo;
  late CartService cart;
  late AnalyticsService analytics;

  setUp(() {
    Get.testMode = true;
    repo = Get.put<DealRepo>(ControlledRepo()) as ControlledRepo;
    cart = Get.put(CartService(orderRepo: ImmediateOrderRepo()));
    analytics = Get.put(AnalyticsService(sendBatch: (_) async {}));
  });
  tearDown(() {
    Get.reset();
    cart.itemCount.close();
    cart.items.close();
    analytics.events.close();
    Get.testMode = false;
  });

  Future<void> open(WidgetTester tester, String route,
      {Object? arguments, bool initialLink = false}) async {
    await tester.pumpWidget(GetMaterialApp(
      initialRoute: initialLink ? route : '/test-home',
      defaultTransition: Transition.noTransition,
      getPages: [
        GetPage(name: '/test-home', page: () => const Scaffold()),
        Routes.pages.firstWhere((page) => page.name == Routes.deal),
      ],
    ));
    if (!initialLink) Get.toNamed(route, arguments: arguments);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> finish(WidgetTester tester) async {
    cart.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('push URI loads deal 42 and Add to bag works', (tester) async {
    // Same path/query conversion as Home's Simulate deep link dialog.
    final uri = Uri.parse('rescu://open/deal?id=42&source=push');
    await open(tester, '${uri.path}?${uri.query}');
    expect(repo.ids, [42]);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.pending.single.complete(fixture(42));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Deal 42'), findsOneWidget);
    expect(find.text('Test bakery'), findsOneWidget);
    expect(find.text('7 left'), findsOneWidget);
    expect(find.textContaining('06:00 – 09:30'), findsOneWidget);
    final event =
        analytics.events.singleWhere((e) => e.name == 'deal_details_view');
    expect(event.properties, {'deal_id': 42, 'source': 'push'});
    await tester.tap(find.text('Add to bag'));
    await tester.pump();
    expect(cart.itemCount.value, 1);
    expect(repo.ids, [42, 42]);
    repo.pending.last.complete(fixture(42));
    await tester.pump(const Duration(seconds: 3));
    await finish(tester);
  });

  testWidgets('Home argument opens immediately without fetching',
      (tester) async {
    final deal = fixture(12);
    await open(tester, Routes.dealRoute(12, source: 'home_feed'),
        arguments: deal);
    expect(Get.find<DealDetailsController>().deal, same(deal));
    expect(find.text('Deal 12'), findsOneWidget);
    expect(repo.ids, isEmpty);
    await finish(tester);
  });

  testWidgets('full rescu URI works as the initial named route',
      (tester) async {
    await open(tester, 'rescu://open/deal?id=42&source=push',
        initialLink: true);
    expect(repo.ids, [42]);
    repo.pending.single.complete(fixture(42));
    await tester.pump();
    expect(find.text('Deal 42'), findsOneWidget);
    expect(find.text('Add to bag'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  for (final query in ['', '?id=abc', '?id=0', '?id=-1']) {
    testWidgets('invalid link $query has no request or cart action',
        (tester) async {
      await open(tester, '${Routes.deal}$query');
      expect(find.text('This deal link is invalid.'), findsOneWidget);
      expect(find.text('Add to bag'), findsNothing);
      expect(repo.ids, isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }

  testWidgets('failed request can retry and reach the real deal',
      (tester) async {
    await open(tester, Routes.dealRoute(42, source: 'push'));
    repo.pending.single
        .completeError(const ApiException('Not found', statusCode: 404));
    await tester.pump();
    expect(find.text('Add to bag'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(repo.ids, [42, 42]);
    repo.pending.last.complete(fixture(42));
    await tester.pump();
    expect(find.text('Deal 42'), findsOneWidget);
    expect(find.text('Add to bag'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('closing during fetch never registers a late cart worker',
      (tester) async {
    await open(tester, Routes.dealRoute(42, source: 'push'));
    final closed = Get.find<DealDetailsController>();
    Get.back();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed.isClosed, isTrue);
    repo.pending.single.complete(fixture(42));
    await tester.pump();
    cart.add(fixture(42));
    await tester.pump();
    expect(repo.ids, [42]);
    expect(
        analytics.events.where((e) => e.name == 'deal_details_view'), isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('route ID takes precedence over a mismatched argument',
      (tester) async {
    await open(tester, Routes.dealRoute(42), arguments: fixture(12));
    expect(repo.ids, [42]);
    repo.pending.single.complete(fixture(42));
    await tester.pump();
    expect(find.text('Deal 42'), findsOneWidget);
    expect(find.text('Deal 12'), findsNothing);
    await finish(tester);
  });
}
