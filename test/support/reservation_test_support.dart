import 'dart:async';
import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/order_model.dart';
import 'package:rescu/model/reservation_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

DealModel reservationDeal(int id, {DateTime? flashEnd, int stock = 10}) =>
    DealModel.fromJson({
      'id': id,
      'name': 'Deal $id',
      'quantityLeft': stock,
      'price': 50,
      'flashSaleEndsAt': flashEnd?.toIso8601String(),
      'pickupWindow': {
        'start': '2026-09-10T00:00:00Z',
        'end': '2026-09-10T02:00:00Z'
      }
    });

OrderModel reservationOrder() => OrderModel.fromJson({
      'id': 123,
      'pickupStart': '2026-09-10T00:00:00Z',
      'pickupEnd': '2026-09-10T02:00:00Z'
    });

/// Existing feature tests use successful holds without starting the fake backend.
class ImmediateOrderRepo extends OrderRepo {
  ImmediateOrderRepo({DateTime Function()? now})
      : now = now ?? DateTime.now,
        super(api: FakeApiService());
  final DateTime Function() now;
  int sequence = 0;
  int checkouts = 0;
  @override
  Future<ReservationModel> reserve(int dealId, {int quantity = 1}) async =>
      ReservationModel(
          id: 'hold_${++sequence}',
          dealId: dealId,
          quantity: quantity,
          expiresAt: now().add(const Duration(minutes: 5)));
  @override
  Future<void> releaseReservation(String reservationId) async {}
  @override
  Future<OrderModel> checkout(List<CartItemModel> items) async {
    checkouts++;
    return reservationOrder();
  }
}

class HoldRequest {
  HoldRequest(this.dealId, this.quantity);
  final int dealId;
  final int quantity;
  final result = Completer<ReservationModel>();
}

class ControlledOrderRepo extends OrderRepo {
  ControlledOrderRepo() : super(api: FakeApiService());
  final holds = <HoldRequest>[];
  final releases = <String>[];
  final releaseResults = <Completer<void>>[];
  bool controlRelease = false;
  final checkouts = <List<CartItemModel>>[];
  final checkoutResults = <Completer<OrderModel>>[];
  @override
  Future<ReservationModel> reserve(int dealId, {int quantity = 1}) {
    final request = HoldRequest(dealId, quantity);
    holds.add(request);
    return request.result.future;
  }

  void accept(int index, DateTime expiry,
      {String? id, int? quantity, int? dealId}) {
    final request = holds[index];
    request.result.complete(ReservationModel(
        id: id ?? 'r$index',
        dealId: dealId ?? request.dealId,
        quantity: quantity ?? request.quantity,
        expiresAt: expiry));
  }

  @override
  Future<void> releaseReservation(String id) {
    releases.add(id);
    if (!controlRelease) return Future.value();
    final request = Completer<void>();
    releaseResults.add(request);
    return request.future;
  }

  @override
  Future<OrderModel> checkout(List<CartItemModel> items) {
    checkouts.add(items);
    final request = Completer<OrderModel>();
    checkoutResults.add(request);
    return request.future;
  }
}
