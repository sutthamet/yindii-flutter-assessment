import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';

DealModel makeDeal(int id, {int stock = 10}) => DealModel.fromJson({
      'id': id,
      'quantityLeft': stock,
      'pickupWindow': {
        'start': '2026-01-01T10:00:00Z',
        'end': '2026-01-01T12:00:00Z',
      },
    });

class RecordingDealRepo extends DealRepo {
  RecordingDealRepo() : super(api: FakeApiService());

  final requestedIds = <int>[];

  @override
  Future<DealModel> fetchById(int id) async {
    requestedIds.add(id);
    return makeDeal(id, stock: 7);
  }
}

void main() {
  late CartService cart;
  late RecordingDealRepo repo;
  late AnalyticsService analytics;

  setUp(() {
    Get.testMode = true;
    cart = CartService();
    repo = RecordingDealRepo();
    analytics = AnalyticsService(sendBatch: (_) async {});
  });

  tearDown(() {
    Get.reset();
    // Also release subscriptions from the buggy version during before testing.
    cart.itemCount.close();
    cart.items.close();
    analytics.events.close();
    Get.testMode = false;
  });

  DealDetailsController openDeal(int id) {
    // Supply the same argument read by onInit during normal route navigation.
    Get.routing.args = makeDeal(id);
    return Get.put(DealDetailsController(
      dealRepo: repo,
      cartService: cart,
      analytics: analytics,
    ));
  }

  testWidgets('closed controllers ignore cart changes; active one refreshes',
      (tester) async {
    for (final id in [1, 2]) {
      final closed = openDeal(id);
      await tester.pump();
      expect(await Get.delete<DealDetailsController>(), isTrue);
      expect(closed.isClosed, isTrue);
    }

    final active = openDeal(3);
    await tester.pump();
    expect(active.quantityLeft, 10);
    expect(repo.requestedIds, isEmpty);

    cart.add(makeDeal(3));
    await tester.pump();
    expect(cart.itemCount.value, 1);
    expect(repo.requestedIds, [3]);
    expect(active.quantityLeft, 7);

    await Get.delete<DealDetailsController>();
    cart.clear();
    await tester.pump();
    expect(repo.requestedIds, [3]);
  });

  testWidgets('reopening the same deal does not duplicate subscriptions',
      (tester) async {
    for (var visit = 0; visit < 3; visit++) {
      final active = openDeal(42);
      await tester.pump();
      cart.add(makeDeal(42));
      await tester.pump();
      expect(repo.requestedIds, List.filled(visit + 1, 42));
      expect(active.quantityLeft, 7);
      await Get.delete<DealDetailsController>();
    }

    cart.clear();
    await tester.pump();
    expect(repo.requestedIds, [42, 42, 42]);
  });
}
