// Manual DevTools stress target; not the submission app's entry point.
// flutter run --profile -t test/support/flash_sale_profile.dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/shared_widget/flash_sale_countdown.dart';
import 'package:rescu/service/cart_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Get.put(CartService(), permanent: true);
  runApp(const GetMaterialApp(home: FlashSaleProfile()));
}

/// All 120 countdowns are mounted together, unlike a lazily built feed.
/// Use the regular app separately to profile images, scrolling and bag flows.
class FlashSaleProfile extends StatefulWidget {
  const FlashSaleProfile({super.key});

  @override
  State<FlashSaleProfile> createState() => _FlashSaleProfileState();
}

class _FlashSaleProfileState extends State<FlashSaleProfile> {
  DateTime _end =
      Get.find<CartService>().clock.now.add(const Duration(minutes: 2));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('F-1: 120 countdowns')),
        body: Column(children: [
          const Text('Profile stress fixture — no FPS claim'),
          TextButton(
            onPressed: () => setState(() => _end = Get.find<CartService>()
                .clock
                .now
                .add(const Duration(minutes: 2))),
            child: const Text('Restart two-minute countdowns'),
          ),
          Expanded(
              child: Column(
                  children: List.generate(
                      20,
                      (row) => Expanded(
                            child: Row(
                                children: List.generate(
                                    6,
                                    (column) => Expanded(
                                          child: FlashSaleExpiry(
                                            endsAt: _end,
                                            builder:
                                                (context, expired, child) =>
                                                    Opacity(
                                              opacity: expired ? 0.5 : 1,
                                              child: child,
                                            ),
                                            child: FittedBox(
                                                child: FlashSaleCountdown(
                                                    endsAt: _end)),
                                          ),
                                        ))),
                          )))),
        ]),
      );
}
