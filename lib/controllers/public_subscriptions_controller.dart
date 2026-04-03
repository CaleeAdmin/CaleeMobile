import 'package:get/get.dart';
import 'package:caleesync/services/public_subscriptions_service.dart';

import '../entity/public_subscription.dart';

class PublicSubscriptionsController extends GetxController {
  final RxBool isLoading = false.obs;
  final RxString error = ''.obs;
  final RxList<PublicSubscriptionCategory> categories = <PublicSubscriptionCategory>[].obs;

  final PublicSubscriptionsService _service = PublicSubscriptionsService();

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    try {
      isLoading.value = true;
      error.value = '';
      categories.clear();
      final List<PublicSubscriptionCategory> result = await _service.fetch();
      categories.assignAll(result);
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }
}


