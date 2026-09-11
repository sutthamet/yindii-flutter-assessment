import 'package:flutter/material.dart';

import '../../../service/flash_sale_clock.dart';

/// Only this text listens to ticks; the line and list do not rebuild each second.
class ReservationCountdown extends StatelessWidget {
  const ReservationCountdown(
      {super.key, required this.expiresAt, required this.clock});

  final DateTime expiresAt;
  final FlashSaleClock clock;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: clock,
        builder: (context, _) => Text(
          clock.isExpired(expiresAt)
              ? 'Hold expired'
              : 'Reserved for ${flashSaleLabel(expiresAt, clock.now)}',
          style: const TextStyle(fontSize: 12.5),
        ),
      );
}
