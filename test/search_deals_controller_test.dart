import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rescu/feature/search/search_deals_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

// Each request is completed explicitly, without random backend delays.
class ControlledDealRepo extends DealRepo {
  ControlledDealRepo() : super(api: FakeApiService());

  final requests = <Completer<List<DealModel>>>[];

  @override
  Future<List<DealModel>> search(String query) {
    final request = Completer<List<DealModel>>();
    requests.add(request);
    return request.future;
  }
}

DealModel deal(int id) => DealModel.fromJson({
      'id': id,
      'pickupWindow': {
        'start': '2026-01-01T10:00:00Z',
        'end': '2026-01-01T12:00:00Z',
      },
    });

Future<void> flushResponses() => Future<void>.delayed(Duration.zero);

void main() {
  late ControlledDealRepo repo;
  late SearchDealsController controller;

  setUp(() {
    repo = ControlledDealRepo();
    controller = SearchDealsController(dealRepo: repo);
  });

  test('older response cannot replace the latest search results', () async {
    controller.onQueryChanged('s');
    controller.onQueryChanged('sushi');
    repo.requests[1].complete([deal(2)]);
    await flushResponses();
    expect(controller.results.single.id, 2);

    repo.requests[0].complete([deal(1)]);
    await flushResponses();
    expect(controller.results.single.id, 2);
    expect(controller.isLoading.value, isFalse);
  });

  for (final fails in [false, true]) {
    test('stale ${fails ? 'error' : 'success'} cannot stop latest loading',
        () async {
      controller.onQueryChanged('s');
      controller.onQueryChanged('sushi');
      if (fails) {
        repo.requests[0].completeError(Exception('old request failed'));
      } else {
        repo.requests[0].complete([deal(1)]);
      }
      await flushResponses();
      expect(controller.isLoading.value, isTrue);
      expect(controller.results, isEmpty);

      repo.requests[1].complete([deal(2)]);
      await flushResponses();
      expect(controller.isLoading.value, isFalse);
      expect(controller.results.single.id, 2);
    });
  }

  test('clearing during loading prevents pending results from returning',
      () async {
    controller.onQueryChanged('sushi');
    controller.onQueryChanged('   ');
    expect(repo.requests, hasLength(1));
    expect(controller.isLoading.value, isFalse);
    expect(controller.hasSearched.value, isFalse);

    repo.requests[0].complete([deal(1)]);
    await flushResponses();
    expect(controller.results, isEmpty);
    expect(controller.hasSearched.value, isFalse);
    expect(controller.isLoading.value, isFalse);
  });

  test('repeating a query still rejects its earlier request', () async {
    controller.onQueryChanged('sushi');
    controller.onQueryChanged('');
    controller.onQueryChanged('sushi');
    repo.requests[1].complete([deal(2)]);
    await flushResponses();
    repo.requests[0].complete([deal(1)]);
    await flushResponses();
    expect(controller.results.single.id, 2);
  });

  test('latest failure ends loading and a subsequent search can succeed',
      () async {
    controller.onQueryChanged('sushi');
    repo.requests[0].completeError(Exception('latest request failed'));
    await flushResponses();
    expect(controller.isLoading.value, isFalse);

    controller.onQueryChanged('bakery');
    repo.requests[1].complete([deal(3)]);
    await flushResponses();
    expect(controller.results.single.id, 3);
    expect(controller.isLoading.value, isFalse);
  });
}
