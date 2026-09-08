import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../service/analytics_service.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class DealDetailsController extends GetxController {
  final DealRepo dealRepo;
  final CartService cartService;
  final AnalyticsService analytics;

  DealDetailsController({
    required this.dealRepo,
    required this.cartService,
    required this.analytics,
  });

  late final DealModel deal;
  Worker? _cartWorker;
  final isLoading = true.obs;
  final loadError = RxnString();
  int? _requestedId;
  bool _fetching = false;
  late final String _source;

  final _quantityLeft = RxnInt();
  int? get quantityLeft => _quantityLeft.value;

  @override
  void onInit() {
    super.onInit();
    _source = Get.parameters['source'] ?? 'unknown';
    final argument = Get.arguments;
    final rawId = Get.parameters['id'];
    _requestedId = int.tryParse(rawId ?? '');
    if (rawId != null && (_requestedId == null || _requestedId! <= 0)) {
      loadError.value = 'This deal link is invalid.';
      isLoading.value = false;
    } else if (argument is DealModel &&
        (rawId == null || argument.id == _requestedId)) {
      _acceptDeal(argument);
    } else if (_requestedId != null) {
      loadDeal();
    } else {
      loadError.value = 'This deal link is invalid.';
      isLoading.value = false;
    }
  }

  bool get canRetry => _requestedId != null && _requestedId! > 0;

  Future<void> loadDeal() async {
    if (!canRetry ||
        isClosed ||
        _fetching ||
        (!isLoading.value && loadError.value == null)) {
      return;
    }
    _fetching = true;
    loadError.value = null;
    isLoading.value = true;
    try {
      final found = await dealRepo.fetchById(_requestedId!);
      if (isClosed) return;
      _acceptDeal(found);
    } catch (error) {
      if (isClosed) return;
      LogService.error('loading deal failed', error);
      loadError.value = 'Unable to load this deal. Please try again.';
      isLoading.value = false;
    } finally {
      _fetching = false;
    }
  }

  void _acceptDeal(DealModel found) {
    deal = found;
    _quantityLeft.value = deal.quantityLeft;
    analytics.logEvent('deal_details_view', {
      'deal_id': deal.id,
      'source': _source,
    });
    // Whenever the cart changes, re-check this deal's remaining stock so the
    // details screen never shows stale availability.
    _cartWorker = ever(cartService.itemCount, (_) => _recheckAvailability());
    isLoading.value = false;
  }

  @override
  void onClose() {
    _cartWorker?.dispose();
    super.onClose();
  }

  Future<void> _recheckAvailability() async {
    LogService.log('re-checking availability for deal ${deal.id}');
    final fresh = await dealRepo.fetchById(deal.id);
    _quantityLeft.value = fresh.quantityLeft;
  }

  void addToCart() {
    if (!cartService.add(deal)) return;
    Get.snackbar(
      'Added to bag',
      '${deal.name} — pick up ${deal.pickupWindow.label}',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
}
