import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

class PageRequest {
  PageRequest(this.page);
  final int page;
  final result = Completer<PagedResponseModel<DealModel>>();

  void complete(List<int> ids, {int totalPages = 3}) {
    result.complete(PagedResponseModel(
      items: ids
          .map((id) => DealModel.fromJson({
                'id': id,
                'pickupWindow': {
                  'start': '2026-01-01T10:00:00Z',
                  'end': '2026-01-01T12:00:00Z',
                },
              }))
          .toList(),
      page: page,
      totalPages: totalPages,
    ));
  }
}

class ControlledHomeRepo extends DealRepo {
  ControlledHomeRepo() : super(api: FakeApiService());
  final requests = <PageRequest>[];

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) {
    final request = PageRequest(page);
    requests.add(request);
    return request.result.future;
  }
}

Future<void> pumpFrame(WidgetTester tester) {
  // No screen is mounted in these controller tests, so explicitly request
  // the frame that runs RefreshController completion callbacks.
  tester.binding.scheduleFrame();
  return tester.pump();
}

void main() {
  late ControlledHomeRepo repo;
  late HomeController controller;

  setUp(() {
    repo = ControlledHomeRepo();
    controller = HomeController(dealRepo: repo);
  });

  tearDown(() => controller.onClose());

  List<int> ids() => controller.deals.map((deal) => deal.id).toList();

  Future<void> seed(WidgetTester tester, {int totalPages = 3}) async {
    final refresh = controller.refreshDeals();
    repo.requests.last.complete([1, 2], totalPages: totalPages);
    await refresh;
    await pumpFrame(tester);
  }

  testWidgets('stale page after refresh never appends or duplicates next page',
      (tester) async {
    await seed(tester);
    final oldLoad = controller.loadMore();
    final oldRequest = repo.requests.last;
    final refresh = controller.refreshDeals();
    repo.requests.last.complete([10, 20]);
    await refresh;
    oldRequest.complete([3, 4]);
    await oldLoad;
    expect(ids(), [10, 20]);

    final next = controller.loadMore();
    expect(repo.requests.last.page, 2);
    repo.requests.last.complete([30, 40]);
    await next;
    expect(ids(), [10, 20, 30, 40]);
    await pumpFrame(tester);
  });

  testWidgets('old page completing during refresh cannot change visible feed',
      (tester) async {
    await seed(tester);
    final oldLoad = controller.loadMore();
    final oldRequest = repo.requests.last;
    final refresh = controller.refreshDeals();
    oldRequest.complete([3, 4]);
    await oldLoad;
    expect(ids(), [1, 2]);
    repo.requests.last.complete([10, 20]);
    await refresh;
    expect(ids(), [10, 20]);
    await pumpFrame(tester);
  });

  for (final fails in [false, true]) {
    testWidgets('stale ${fails ? 'error' : 'success'} cannot unlock new load',
        (tester) async {
      await seed(tester);
      final oldLoad = controller.loadMore();
      final oldRequest = repo.requests.last;
      final refresh = controller.refreshDeals();
      repo.requests.last.complete([10, 20]);
      await refresh;
      await pumpFrame(tester);

      final next = controller.loadMore();
      expect(repo.requests.map((r) => r.page), [1, 2, 1, 2]);
      controller.refreshController.footerMode!.value = LoadStatus.loading;
      if (fails) {
        oldRequest.result.completeError(Exception('old page failed'));
      } else {
        oldRequest.complete([3, 4]);
      }
      await oldLoad;
      await pumpFrame(tester);
      expect(
          controller.refreshController.footerMode!.value, LoadStatus.loading);
      await controller.loadMore();
      expect(repo.requests, hasLength(4));
      repo.requests.last.complete([30, 40]);
      await next;
      expect(ids(), [10, 20, 30, 40]);
      await pumpFrame(tester);
    });
  }

  testWidgets('failed refresh preserves accepted pages and next page number',
      (tester) async {
    await seed(tester);
    final page2 = controller.loadMore();
    repo.requests.last.complete([3, 4]);
    await page2;
    await pumpFrame(tester);
    final oldLoad = controller.loadMore();
    final oldRequest = repo.requests.last;
    // Consume the original implementation's thrown refresh error so assertions
    // check pagination behavior rather than merely an unhandled exception.
    final refresh = controller
        .refreshDeals()
        .then<void>((_) {}, onError: (Object error) {});
    repo.requests.last.result.completeError(Exception('refresh failed'));
    await refresh;
    oldRequest.result.completeError(Exception('superseded page failed'));
    await oldLoad;
    expect(ids(), [1, 2, 3, 4]);
    final retry = controller.loadMore();
    expect(repo.requests.last.page, 3);
    repo.requests.last.complete([5, 6]);
    await retry;
    expect(ids(), [1, 2, 3, 4, 5, 6]);
    await pumpFrame(tester);
    expect(
        controller.refreshController.headerMode!.value, RefreshStatus.failed);
  });

  testWidgets('only the latest overlapping refresh can replace the feed',
      (tester) async {
    await seed(tester);
    final first = controller.refreshDeals();
    final firstRequest = repo.requests.last;
    final second = controller.refreshDeals();
    repo.requests.last.complete([10, 20], totalPages: 2);
    await second;
    firstRequest.complete([100, 200], totalPages: 1);
    await first;
    expect(ids(), [10, 20]);
    expect(controller.hasMore, isTrue);
    await pumpFrame(tester);
  });

  testWidgets('load more is blocked while refresh owns the feed',
      (tester) async {
    await seed(tester);
    final refresh = controller.refreshDeals();
    final request = repo.requests.last;
    final ignored = controller.loadMore();
    expect(repo.requests, hasLength(2));
    request.complete([10, 20]);
    await refresh;
    await ignored;
    await pumpFrame(tester);
  });

  testWidgets('refresh resets noMore footer and allows page two again',
      (tester) async {
    await seed(tester, totalPages: 1);
    await controller.loadMore();
    await pumpFrame(tester);
    expect(controller.refreshController.footerMode!.value, LoadStatus.noMore);
    final refresh = controller.refreshDeals();
    repo.requests.last.complete([10, 20], totalPages: 2);
    await refresh;
    await pumpFrame(tester);
    expect(controller.refreshController.footerMode!.value, LoadStatus.idle);
    final next = controller.loadMore();
    expect(repo.requests.last.page, 2);
    repo.requests.last.complete([30, 40], totalPages: 2);
    await next;
    expect(ids(), [10, 20, 30, 40]);
    await pumpFrame(tester);
  });

  testWidgets('failed page can retry without advancing accepted pagination',
      (tester) async {
    await seed(tester, totalPages: 2);
    final load = controller.loadMore();
    expect(controller.hasMore, isTrue);
    await controller.loadMore();
    expect(repo.requests, hasLength(2));
    repo.requests.last.result.completeError(Exception('page failed'));
    await load;
    await pumpFrame(tester);
    expect(ids(), [1, 2]);
    expect(controller.refreshController.footerMode!.value, LoadStatus.failed);
    final retry = controller.loadMore();
    expect(repo.requests.last.page, 2);
    repo.requests.last.complete([3, 4], totalPages: 2);
    await retry;
    expect(controller.hasMore, isFalse);
    await pumpFrame(tester);
  });

  testWidgets('queued completion cannot reset a newer loading footer',
      (tester) async {
    await seed(tester);
    final page2 = controller.loadMore();
    repo.requests.last.complete([3, 4]);
    await page2;
    // Start the next operation before the old completion's post-frame callback.
    final page3 = controller.loadMore();
    controller.refreshController.footerMode!.value = LoadStatus.loading;
    await pumpFrame(tester);
    expect(controller.refreshController.footerMode!.value, LoadStatus.loading);
    repo.requests.last.complete([5, 6]);
    await page3;
    await pumpFrame(tester);
  });

  testWidgets('empty refreshed catalog replaces old data and stops pagination',
      (tester) async {
    await seed(tester);
    final refresh = controller.refreshDeals();
    repo.requests.last.complete([], totalPages: 0);
    await refresh;
    await pumpFrame(tester);
    expect(ids(), isEmpty);
    expect(controller.hasMore, isFalse);
    await controller.loadMore();
    expect(repo.requests, hasLength(2));
    await pumpFrame(tester);
    expect(controller.refreshController.footerMode!.value, LoadStatus.noMore);
  });
}
