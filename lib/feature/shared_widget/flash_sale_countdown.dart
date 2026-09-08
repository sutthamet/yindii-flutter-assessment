import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../service/cart_service.dart';
import '../../service/flash_sale_clock.dart';

class FlashSaleCountdown extends StatelessWidget {
  const FlashSaleCountdown({super.key, required this.endsAt, this.style});

  final DateTime endsAt;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final clock = Get.find<CartService>().clock;
    return ListenableBuilder(
      listenable: clock,
      builder: (context, _) =>
          Text(flashSaleLabel(endsAt, clock.now), style: style),
    );
  }
}

/// Only notifies the builder when expiry changes, not on every clock tick.
/// The prebuilt child (including images) is preserved across that transition.
class FlashSaleExpiry extends StatefulWidget {
  const FlashSaleExpiry({
    super.key,
    required this.endsAt,
    required this.builder,
    this.child,
  });

  final DateTime? endsAt;
  final Widget Function(BuildContext, bool expired, Widget? child) builder;
  final Widget? child;

  @override
  State<FlashSaleExpiry> createState() => _FlashSaleExpiryState();
}

class _FlashSaleExpiryState extends State<FlashSaleExpiry> {
  FlashSaleClock? _clock;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    if (widget.endsAt != null) {
      _clock = Get.find<CartService>().clock;
      _expired = _clock!.isExpired(widget.endsAt);
      _clock!.addListener(_tick);
    } else {
      _expired = false;
    }
  }

  void _tick() {
    final expired = _clock!.isExpired(widget.endsAt);
    if (expired != _expired) setState(() => _expired = expired);
  }

  @override
  void didUpdateWidget(FlashSaleExpiry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endsAt != widget.endsAt) {
      _clock?.removeListener(_tick);
      _clock = null;
      _subscribe();
    }
  }

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _expired, widget.child);
}
