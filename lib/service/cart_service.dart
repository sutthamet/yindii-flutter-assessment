import 'dart:async';
import 'package:get/get.dart';
import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../model/order_model.dart';
import '../model/reservation_model.dart';
import '../repository/order_repo.dart';
import '../util/log_service.dart';
import 'api_exception.dart';
import 'flash_sale_clock.dart';

/// Session owner of optimistic bag edits, server holds and checkout.
class CartService extends GetxService {
  CartService(
      {required this.orderRepo,
      FlashSaleClock? clock,
      void Function(String)? onExpiryNotice,
      void Function(String)? onNotice})
      : clock = clock ?? FlashSaleClock(),
        _ownsClock = clock == null,
        _onExpiryNotice = onExpiryNotice ?? _showExpiryNotice,
        _onNotice = onNotice ?? _showNotice;
  final OrderRepo orderRepo;
  final FlashSaleClock clock;
  final bool _ownsClock;
  final void Function(String) _onExpiryNotice;
  final void Function(String) _onNotice;
  bool _watchingExpiry = false;
  bool _closed = false;
  int _sequence = 0;
  final _operations = <int, int>{};
  final _submittedIds = <String>{};
  final _releasing = <String>{};
  final _releaseTimers = <Timer>{};
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;
  final isCheckingOut = false.obs;

  static void _showExpiryNotice(String message) =>
      Get.snackbar('Bag updated', message, snackPosition: SnackPosition.BOTTOM);
  static void _showNotice(String message) =>
      Get.snackbar('My bag', message, snackPosition: SnackPosition.BOTTOM);

  bool canAdd(DealModel deal) {
    final line = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    return !_closed &&
        !isCheckingOut.value &&
        !clock.isExpired(deal.flashSaleEndsAt) &&
        (line == null || !line.isPending) &&
        (line?.quantity ?? 0) < deal.quantityLeft;
  }

  bool add(DealModel deal) {
    if (_closed || isCheckingOut.value) return false;
    if (clock.isExpired(deal.flashSaleEndsAt)) {
      if (!removeExpired()) {
        _onExpiryNotice('${deal.name} has expired and cannot be added.');
      }
      return false;
    }
    if (removeExpired()) {
      return false; // Do not renew an expired quantity implicitly.
    }
    if (!canAdd(deal)) return false;
    final existing = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    final line = existing ?? CartItemModel(deal: deal);
    if (existing != null) line.quantity++;
    line.isUpdating = true;
    if (existing == null) items.add(line);
    _startReservation(line);
    return true;
  }

  void decrement(int dealId) {
    if (_closed || isCheckingOut.value) return;
    if (removeExpired()) return;
    final line = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (line == null || line.isPending) return;
    if (line.quantity == 1) {
      remove(dealId);
    } else {
      line.quantity--;
      line.isUpdating = true;
      _startReservation(line);
    }
  }

  void _startReservation(CartItemModel line) {
    final version = ++_sequence;
    _operations[line.deal.id] = version;
    final previous = line.reservation;
    // This operation owns the old hold until release finishes, even if removed.
    line.reservation = null;
    _changed();
    unawaited(_reserve(line, version, previous));
  }

  bool _current(CartItemModel line, int version) =>
      !_closed && _operations[line.deal.id] == version && items.contains(line);

  Future<void> _reserve(
      CartItemModel line, int version, ReservationModel? previous) async {
    if (previous != null) {
      try {
        await orderRepo.releaseReservation(previous.id);
      } catch (error) {
        LogService.error('replacing reservation: release failed', error);
        _release(previous);
        _rollback(line, version);
        return;
      }
    }
    if (!_current(line, version)) return;
    try {
      final reservation =
          await orderRepo.reserve(line.deal.id, quantity: line.quantity);
      if (!_current(line, version)) {
        _release(reservation);
        return;
      }
      if (clock.isExpired(line.deal.flashSaleEndsAt) ||
          !_validReservation(reservation, line)) {
        _release(reservation);
        _rollback(line, version);
        return;
      }
      line.reservation = reservation;
      line.isUpdating = false;
      _changed();
    } catch (error) {
      LogService.error('reservation failed', error);
      _rollback(line, version);
    }
  }

  void _rollback(CartItemModel line, int version) {
    if (!_current(line, version)) return;
    _removeLine(line);
    _changed();
    _onNotice(
        'We could not hold ${line.deal.name}. It was removed from your bag. Please try again.');
  }

  bool _validReservation(ReservationModel hold, CartItemModel line) =>
      hold.id.isNotEmpty &&
      hold.dealId == line.deal.id &&
      hold.quantity == line.quantity &&
      !hold.isExpiredAt(clock.now);

  bool get canCheckout =>
      !_closed &&
      !isCheckingOut.value &&
      items.isNotEmpty &&
      items.every((line) =>
          !line.isPending &&
          !clock.isExpired(line.deal.flashSaleEndsAt) &&
          _validReservation(line.reservation!, line));

  /// The session, not the bag route, owns the checkout request and lock.
  Future<OrderModel?> checkout() async {
    if (_closed || isCheckingOut.value) return null;
    if (removeExpired()) return null; // Review a changed bag before paying.
    if (!canCheckout) {
      if (items.isNotEmpty) {
        _onNotice(
            'Please wait until all items are reserved before checking out.');
      }
      return null;
    }
    isCheckingOut.value = true;
    final snapshot = items
        .map((line) => CartItemModel(
            deal: line.deal,
            quantity: line.quantity,
            reservation: line.reservation))
        .toList();
    _submittedIds.addAll(snapshot.map((line) => line.reservation!.id));
    var success = false;
    try {
      final order = await orderRepo.checkout(snapshot);
      success = true;
      if (!_closed) {
        for (final line in items.toList()) {
          if (_submittedIds.contains(line.reservation?.id)) _removeLine(line);
        }
        _changed();
        _onNotice(
            'Order #${order.id} confirmed. Please check My orders for pickup details.');
      }
      return order;
    } catch (error) {
      LogService.error('checkout failed', error);
      if (!_closed) {
        if (error is ApiException && error.statusCode == 410) {
          // No offending line is provided by the API: do not reuse this set.
          for (final line in items.toList()) {
            if (_submittedIds.contains(line.reservation?.id)) _removeLine(line);
          }
          _changed();
          _onNotice(
              'Your holds are no longer valid. Please add the items again before checking out.');
        } else {
          removeExpired();
          _onNotice(
              'Checkout could not be completed. Your remaining reserved items are still in your bag. Please try again.');
        }
      }
      return null;
    } finally {
      _submittedIds.clear();
      for (final line in snapshot) {
        final hold = line.reservation!;
        if (_closed ||
            success ||
            !items.any((i) => i.reservation?.id == hold.id)) {
          _release(hold);
        }
      }
      if (!_closed) isCheckingOut.value = false;
    }
  }

  /// Absolute checks also run on resume and immediately before checkout.
  bool removeExpired() {
    if (_closed) return false;
    final expired = items
        .where((line) =>
            clock.isExpired(line.deal.flashSaleEndsAt) ||
            (line.reservation?.isExpiredAt(clock.now) ?? false))
        .toList();
    if (expired.isEmpty) return false;
    for (final line in expired) {
      _removeLine(line);
    }
    _changed();
    final checking =
        isCheckingOut.value ? ' Your checkout is still being confirmed.' : '';
    _onExpiryNotice(
        '${expired.map((i) => i.deal.name).join(', ')} expired and was removed from your bag.$checking');
    return true;
  }

  void remove(int dealId) {
    if (_closed || isCheckingOut.value) return;
    final line = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (line == null) return;
    _removeLine(line);
    _changed();
  }

  void _removeLine(CartItemModel line) {
    _operations.remove(line.deal.id);
    items.remove(line);
    final hold = line.reservation;
    if (hold != null && !_submittedIds.contains(hold.id)) _release(hold);
  }

  void clear() {
    if (_closed || isCheckingOut.value) return;
    for (final line in items.toList()) {
      _removeLine(line);
    }
    _changed();
  }

  /// Best-effort cleanup: three attempts, then server expiry bounds the hold.
  void _release(ReservationModel hold, [int attempt = 0]) {
    if (hold.id.isEmpty) return;
    if (!_releasing.add(hold.id)) return;
    unawaited(() async {
      try {
        await orderRepo.releaseReservation(hold.id);
        _releasing.remove(hold.id);
      } catch (error) {
        LogService.error('reservation cleanup failed', error);
        if (!_closed && attempt < 2) {
          late final Timer timer;
          timer = Timer(const Duration(seconds: 5), () {
            _releaseTimers.remove(timer);
            _releasing.remove(hold.id);
            _release(hold, attempt + 1);
          });
          _releaseTimers.add(timer);
        } else {
          _releasing.remove(hold.id);
        }
        if (!_closed && attempt == 0) {
          _onNotice(
              'The item is out of your bag, but its hold could not be released yet. It will expire automatically.');
        }
      }
    }());
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _changed() {
    items.refresh();
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
    final shouldWatch =
        items.any((i) => i.deal.isFlashSale || i.reservation != null);
    if (shouldWatch == _watchingExpiry) return;
    _watchingExpiry = shouldWatch;
    if (shouldWatch) {
      clock.addListener(_checkExpiry);
    } else {
      clock.removeListener(_checkExpiry);
    }
  }

  void _checkExpiry() => removeExpired();

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    _operations.clear();
    for (final timer in _releaseTimers) {
      timer.cancel();
    }
    _releaseTimers.clear();
    if (_watchingExpiry) clock.removeListener(_checkExpiry);
    for (final line in items) {
      final hold = line.reservation;
      if (hold != null && !_submittedIds.contains(hold.id)) _release(hold);
    }
    if (_ownsClock) clock.dispose();
    super.onClose();
  }
}
