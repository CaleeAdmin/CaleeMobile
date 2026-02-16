import 'dart:async';

import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../data/database_helper.dart';
import 'CalendarPageController.dart';

class LocalCalendarGroup {
  final String accountName;
  final List<LocalCalendarItem> calendars;

  LocalCalendarGroup({required this.accountName, required this.calendars});
}

class LocalCalendarItem {
  final String id;
  final String name;
  final String accountName;
  final String? accountType;
  final String color;
  final bool isReadOnly;
  final int eventCount;
  bool isConnected;

  LocalCalendarItem({
    required this.id,
    required this.name,
    required this.accountName,
    required this.accountType,
    required this.color,
    required this.isReadOnly,
    required this.eventCount,
    required this.isConnected,
  });
}

class LocalCalendarPageController extends GetxController {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();

  final calendarGroups = <LocalCalendarGroup>[].obs;
  final isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    refreshLocalCalendars();
  }

  Future<void> refreshLocalCalendars() async {
    try {
      isLoading.value = true;

      final bool hasPermission = await _nativeApi.requestPermission(false);
      if (!hasPermission) {
        calendarGroups.clear();
        Get.snackbar('Permission required', 'Calendar access is required to load local calendars.');
        return;
      }

      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> rows = await db.query(
        'calendar_map',
        columns: ['local_id'],
        where: 'origin = 0 AND local_id IS NOT NULL AND local_id != ""',
      );
      final Set<String> connectedLocalIds = {
        for (final row in rows) row['local_id'].toString(),
      };

      final List<Map<String, dynamic>> remoteProvisionedRows = await db.query(
        'calendar_map',
        columns: ['local_id'],
        where: 'origin = 1 AND local_id IS NOT NULL AND local_id != ""',
      );
      final Set<String> remoteProvisionedLocalIds = {
        for (final row in remoteProvisionedRows) row['local_id'].toString(),
      };

      final List<PlatformCalendar?> rawCalendars = await _nativeApi.getCalendars();
      final DateTime now = DateTime.now();
      final int rangeStart = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final int rangeEnd = now.add(const Duration(days: 365)).millisecondsSinceEpoch;

      final Map<String, List<LocalCalendarItem>> grouped = {};

      for (final PlatformCalendar calendar in rawCalendars.whereType<PlatformCalendar>()) {
        if (calendar.supportsEvents == false) {
          continue;
        }

        final String id = calendar.id ?? '';
        if (id.isEmpty) {
          continue;
        }

        if (remoteProvisionedLocalIds.contains(id)) {
          continue;
        }

        final List<PlatformItem?> events = await _nativeApi.getEvents(id, rangeStart, rangeEnd);
        final int eventCount = events.whereType<PlatformItem>().where((event) => event.isTask != true).length;

        final String accountName = (calendar.accountName != null && calendar.accountName!.isNotEmpty)
            ? calendar.accountName!
            : 'Local';

        final item = LocalCalendarItem(
          id: id,
          name: (calendar.name != null && calendar.name!.isNotEmpty) ? calendar.name! : 'Untitled calendar',
          accountName: accountName,
          accountType: calendar.accountType,
          color: calendar.color ?? '#808080',
          isReadOnly: calendar.isReadOnly ?? false,
          eventCount: eventCount,
          isConnected: connectedLocalIds.contains(id),
        );

        grouped.putIfAbsent(accountName, () => []).add(item);
      }

      final List<LocalCalendarGroup> nextGroups = grouped.entries
          .map((entry) => LocalCalendarGroup(accountName: entry.key, calendars: entry.value))
          .toList()
        ..sort((a, b) => a.accountName.toLowerCase().compareTo(b.accountName.toLowerCase()));

      calendarGroups.assignAll(nextGroups);
    } catch (e) {
      debugPrint('❌ Failed to load local calendars: $e');
      Get.snackbar('Error', 'Failed to load local calendars');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> toggleCalendarSelection(
    LocalCalendarItem item,
    bool enabled, {
    bool returnToCalendarListAfterConnect = false,
  }) async {
    final bool previousConnectionState = item.isConnected;
    if (enabled) {
      item.isConnected = true;
    }
    calendarGroups.refresh();

    try {
      final db = await DatabaseHelper.instance.database;
      final int updated = await db.update(
        'calendar_map',
        {
          'is_enabled': enabled ? 1 : 0,
          'display_name': item.name,
          'account_name': item.accountName,
          'account_type': item.accountType,
          'color': item.color,
          'origin': 0,
        },
        where: 'local_id = ?',
        whereArgs: [item.id],
      );

      if (updated == 0) {
        await db.insert('calendar_map', {
          'local_id': item.id,
          'account_name': item.accountName,
          'account_type': item.accountType,
          'display_name': item.name,
          'color': item.color,
          'is_enabled': enabled ? 1 : 0,
          'origin': 0,
        });
      }

      if (enabled && returnToCalendarListAfterConnect) {
        await _refreshMainCalendarList();
        if (Get.isOverlaysOpen == true) {
          Get.closeAllSnackbars();
        }
        if (Get.key.currentState?.canPop() == true) {
          Get.back<void>();
        }
      }
    } catch (e) {
      item.isConnected = previousConnectionState;
      calendarGroups.refresh();
      debugPrint('❌ Failed to update local calendar switch: $e');
      Get.snackbar('Error', 'Unable to update calendar state');
    }
  }

  Future<void> _refreshMainCalendarList() async {
    if (!Get.isRegistered<CalendarPageController>()) {
      return;
    }

    final CalendarPageController dashboardController = Get.find<CalendarPageController>();
    await dashboardController.refreshDashboard(includeEventCounts: false);
    unawaited(dashboardController.refreshDashboard());
  }
}
