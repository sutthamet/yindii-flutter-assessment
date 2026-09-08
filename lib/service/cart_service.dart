import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../util/log_service.dart';
import 'flash_sale_clock.dart';

/// App-wide cart. Lives for the whole session.
///
/// NOTE: the starter cart is purely local — it does not reserve stock on the
/// backend. See the "Reservations" feature task in PROBLEM.md.
class CartService extends GetxService {
  CartService({FlashSaleClock? clock, void Function(String)? onExpiryNotice})
      : clock = clock ?? FlashSaleClock(),
        _ownsClock = clock == null,
        _onExpiryNotice = onExpiryNotice ?? _showExpiryNotice;

  final FlashSaleClock clock;
  final bool _ownsClock;
  final void Function(String) _onExpiryNotice;
  bool _watchingExpiry = false;

  static void _showExpiryNotice(String message) {
    Get.snackbar('Flash sale expired', message,
        snackPosition: SnackPosition.BOTTOM);
  }

  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;

  bool add(DealModel deal) {
    if (clock.isExpired(deal.flashSaleEndsAt)) {
      if (!removeExpired()) {
        _onExpiryNotice('${deal.name} has expired and cannot be added.');
      }
      return false;
    }
    final existing = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    if (existing != null) {
      if (existing.quantity >= deal.quantityLeft) {
        LogService.log('cart: cannot add more of deal ${deal.id}');
        return false;
      }
      existing.quantity++;
      items.refresh();
    } else {
      items.add(CartItemModel(deal: deal));
    }
    _recount();
    return true;
  }

  /// Also called before checkout: the timer is not an authorization boundary.
  bool removeExpired() {
    final expired =
        items.where((i) => clock.isExpired(i.deal.flashSaleEndsAt)).toList();
    if (expired.isEmpty) return false;
    final ids = expired.map((i) => i.deal.id).toSet();
    items.removeWhere((i) => ids.contains(i.deal.id));
    _recount();
    _onExpiryNotice(
        '${expired.map((i) => i.deal.name).join(', ')} expired and was removed from your bag.');
    return true;
  }

  void _checkExpiry() => removeExpired();

  @override
  void onClose() {
    if (_watchingExpiry) clock.removeListener(_checkExpiry);
    if (_ownsClock) clock.dispose();
    super.onClose();
  }

  void decrement(int dealId) {
    final existing = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (existing == null) return;
    existing.quantity--;
    if (existing.quantity <= 0) {
      items.removeWhere((i) => i.deal.id == dealId);
    } else {
      items.refresh();
    }
    _recount();
  }

  void remove(int dealId) {
    items.removeWhere((i) => i.deal.id == dealId);
    _recount();
  }

  void clear() {
    items.clear();
    _recount();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
    final shouldWatch = items.any((i) => i.deal.isFlashSale);
    if (shouldWatch == _watchingExpiry) return;
    _watchingExpiry = shouldWatch;
    if (shouldWatch) {
      clock.addListener(_checkExpiry);
    } else {
      clock.removeListener(_checkExpiry);
    }
  }
}
