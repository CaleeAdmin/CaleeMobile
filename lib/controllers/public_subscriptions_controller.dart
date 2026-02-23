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
    final String server = MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer;
    _service = PublicSubscriptionsService(baseUrl: _normalizeServer(server));
    load();
  }

  String _normalizeServer(String base) {
    var normalized = base.trim();
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'https://$normalized';
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  Future<void> load() async {
    try {
      isLoading.value = true;
      error.value = '';
      categories.clear();
      final String username = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
      final String appPassword = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
      final List<PublicSubscriptionCategory> result = await _service.fetch(username: username, appPassword: appPassword);
      categories.assignAll(result);
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }
}


