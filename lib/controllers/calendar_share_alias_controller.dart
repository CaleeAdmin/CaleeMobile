import 'package:caleesync/entity/calendar_share_alias.dart';
import 'package:caleesync/services/calendar_share_alias_service.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class CalendarShareAliasController extends GetxController {
  final CalendarShareAliasService _service;

  CalendarShareAliasController({CalendarShareAliasService? service})
      : _service = service ?? CalendarShareAliasService();

  final RxBool isLoading = false.obs;
  final RxBool isRotating = false.obs;
  final RxString error = ''.obs;
  final Rxn<CalendarShareAliasDto> alias = Rxn<CalendarShareAliasDto>();

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    isLoading.value = true;
    error.value = '';
    try {
      alias.value = await _service.fetchCurrentAlias();
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> refreshAlias() async {
    error.value = '';
    try {
      alias.value = await _service.fetchCurrentAlias();
    } catch (e) {
      error.value = e.toString();
    }
  }

  Future<bool> rotateAlias() async {
    if (isRotating.value) return false;
    isRotating.value = true;
    error.value = '';
    try {
      final oldAlias = alias.value?.aliasEmail;
      final rotated = await _service.rotateAlias();
      alias.value = CalendarShareAliasDto(
        userUid: rotated.userUid,
        aliasEmail: rotated.aliasEmail,
        token: rotated.token,
        isActive: rotated.isActive,
        wasCreated: rotated.rotatedAt,
        domain: _extractDomain(rotated.aliasEmail),
        copyValue: rotated.aliasEmail,
      );
      if (oldAlias != null && oldAlias == rotated.aliasEmail) {
        return true;
      }
      return true;
    } catch (e) {
      error.value = e.toString();
      return false;
    } finally {
      isRotating.value = false;
    }
  }

  Future<void> copyAlias() async {
    final value = alias.value?.copyValue ?? '';
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
  }

  String _extractDomain(String email) {
    final idx = email.indexOf('@');
    if (idx < 0 || idx + 1 >= email.length) return '';
    return email.substring(idx + 1);
  }
}
