import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class HomeController extends GetxController {
  final DealRepo dealRepo;

  HomeController({required this.dealRepo});

  final deals = <DealModel>[].obs;
  final flashDeals = <DealModel>[].obs;
  final isLoading = true.obs;
  final todayOnly = false.obs;
  final scrollOffset = 0.0.obs;

  final scrollController = ScrollController();
  final refreshController = RefreshController();

  int _page = 0;
  int _totalPages = 1;
  bool _isFetchingMore = false;
  bool _isRefreshing = false;
  int _requestVersion = 0;

  bool get hasMore => _page < _totalPages;

  List<DealModel> get visibleDeals => todayOnly.value
      ? deals.where((d) => d.pickupWindow.isToday).toList()
      : deals.toList();

  @override
  void onInit() {
    super.onInit();
    scrollController.addListener(_onScroll);
    _initialLoad();
  }

  void _onScroll() {
    scrollOffset.value = scrollController.offset;
  }

  Future<void> _initialLoad() async {
    isLoading.value = true;
    try {
      await Future.wait([refreshDeals(), _loadFlashDeals()]);
    } catch (e) {
      LogService.error('initial load failed', e);
    }
    isLoading.value = false;
  }

  Future<void> _loadFlashDeals() async {
    flashDeals.assignAll(await dealRepo.fetchFlashDeals());
  }

  Future<void> refreshDeals() async {
    if (isClosed) return;
    final version = ++_requestVersion;
    _isRefreshing = true;
    _isFetchingMore = false;
    try {
      final res = await dealRepo.fetchDeals(page: 1);
      if (!_isCurrentRequest(version)) return;
      _page = res.page;
      _totalPages = res.totalPages;
      deals.assignAll(res.items);
      refreshController.refreshCompleted();
    } catch (e) {
      if (!_isCurrentRequest(version)) return;
      LogService.error('refresh failed', e);
      refreshController.refreshFailed();
    } finally {
      if (_isCurrentRequest(version)) {
        _isRefreshing = false;
        _setFooter(version, hasMore ? LoadStatus.idle : LoadStatus.noMore);
      }
    }
  }

  Future<void> loadMore() async {
    if (isClosed || _isRefreshing || _isFetchingMore) return;
    if (!hasMore) {
      _setFooter(_requestVersion, LoadStatus.noMore);
      return;
    }
    final version = ++_requestVersion;
    final nextPage = _page + 1;
    _isFetchingMore = true;
    var footerStatus = LoadStatus.idle;
    try {
      final res = await dealRepo.fetchDeals(page: nextPage);
      if (!_isCurrentRequest(version)) return;
      _page = res.page;
      _totalPages = res.totalPages;
      deals.addAll(res.items);
      if (!hasMore) footerStatus = LoadStatus.noMore;
    } catch (e) {
      if (!_isCurrentRequest(version)) return;
      LogService.error('loadMore failed', e);
      footerStatus = LoadStatus.failed;
    } finally {
      if (_isCurrentRequest(version)) {
        _isFetchingMore = false;
        _setFooter(version, footerStatus);
      }
    }
  }

  bool _isCurrentRequest(int version) =>
      !isClosed && version == _requestVersion;

  void _setFooter(int version, LoadStatus status) {
    // Like RefreshController's completion methods, update after the frame,
    // but do not let an old completion overwrite a newer request's footer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isCurrentRequest(version)) {
        refreshController.footerMode?.value = status;
      }
    });
  }

  void scrollToTop() {
    scrollController.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
  }

  @override
  void onClose() {
    _requestVersion++;
    scrollController.dispose();
    refreshController.dispose();
    super.onClose();
  }
}
