import 'package:get/get.dart';
import '../../service/cart_service.dart';

class CartController extends GetxController {
  CartController({required this.cartService});
  final CartService cartService;
  RxBool get isCheckingOut => cartService.isCheckingOut;
  Future<void> checkout() async {
    await cartService.checkout();
  }
}
