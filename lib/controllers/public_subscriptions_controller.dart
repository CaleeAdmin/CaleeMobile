import 'package:caleesync/services/public_subscriptions_service.dart';
import 'package:get/get.dart';

import '../entity/public_subscription.dart';

class PublicSubscriptionsController extends GetxController {
  final RxBool isLoading = false.obs;
  final RxString error = ''.obs;
  final RxList<PublicSubscriptionCategory> categories = <PublicSubscriptionCategory>[].obs;

  late final PublicSubscriptionsService _service;

  @override
  void onInit() {
    super.onInit();
    _service = PublicSubscriptionsService();
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
