import 'package:get/get.dart';
import 'package:caleesync/services/published_calendars_service.dart';

import '../entity/published_calendar.dart';

class PublishedCalendarsController extends GetxController {
  final RxBool isLoading = false.obs;
  final RxString error = ''.obs;
  final RxList<PublishedCalendarCategory> categories = <PublishedCalendarCategory>[].obs;

  final PublishedCalendarsService _service = PublishedCalendarsService();

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
      final List<PublishedCalendarCategory> result = await _service.fetch();
      categories.assignAll(result);
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }
}


