import 'deal_model.dart';
import 'reservation_model.dart';

class CartItemModel {
  final DealModel deal;
  int quantity;

  /// One server hold covers the entire confirmed quantity of this line.
  ReservationModel? reservation;
  bool isUpdating;

  CartItemModel(
      {required this.deal,
      this.quantity = 1,
      this.reservation,
      this.isUpdating = false});

  bool get isPending => isUpdating || reservation == null;

  num get lineTotal => deal.price * quantity;
}
