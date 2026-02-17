import 'package:get/get.dart';
import 'package:caleesync/services/public_subscriptions_service.dart';
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';

import '../entity/public_subscription.dart';

class PublicSubscriptionsController extends GetxController {
  final RxBool isLoading = false.obs;
  final RxString error = ''.obs;
  final RxList<PublicSubscriptionCategory> categories = <PublicSubscriptionCategory>[].obs;

  late final PublicSubscriptionsService _service;

  @override
  void onInit() {
    super.onInit();
    final base = AppConstant.caleeServer;
    _service = PublicSubscriptionsService(baseUrl: "https://portal.calee.com.au");
    load();
  }

  Future<void> load() async {
    try {
      isLoading.value = true;
      error.value = '';
      categories.clear();
      // final String username = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
      // final String appPassword = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
      final List<PublicSubscriptionCategory> result = await _service.fetch(username: "test", appPassword: "Ex75A-3XQNN-yGdzP-dM37J-azidb");
      categories.assignAll(result);
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }
}


