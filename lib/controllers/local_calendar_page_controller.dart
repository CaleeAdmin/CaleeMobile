import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';

import '../data/database_helper.dart';
import '../services/calee_server_service.dart';
import '../sync/relink_verifier.dart';
import '../sync/sync_gate_reason.dart';
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
  final bool isSubscription;
  final String? subscriptionUrl;
  bool isConnected;

  LocalCalendarItem({
    required this.id,
    required this.name,
    required this.accountName,
    required this.accountType,
    required this.color,
    required this.isReadOnly,
    required this.eventCount,
    required this.isSubscription,
    required this.subscriptionUrl,
    required this.isConnected,
  });
}

class LocalCalendarPageController extends GetxController {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final CaleeServerService _caleeService = CaleeServerService();
  final RelinkVerifier _relinkVerifier = RelinkVerifier();

  final calendarGroups = <LocalCalendarGroup>[].obs;
  final isLoading = false.obs;
  final connectingCalendarIds = <String>{}.obs;

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
      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);

      final List<Map<String, dynamic>> rows = await db.rawQuery('''
        SELECT lb.local_collection_id
        FROM local_bindings lb
        INNER JOIN remote_collections rc ON rc.id = lb.remote_collection_id
        WHERE lb.local_collection_id IS NOT NULL
          AND lb.local_collection_id != ''
          AND rc.account_name = ?
      ''', [loginName ?? '']);
      final Set<String> connectedLocalIds = {
        for (final row in rows) row['local_collection_id'].toString(),
      };

      final List<Map<String, dynamic>> remoteProvisionedRows = await db.rawQuery('''
        SELECT lb.local_collection_id
        FROM local_bindings lb
        INNER JOIN remote_collections rc ON rc.id = lb.remote_collection_id
        WHERE rc.origin_kind != 0
          AND lb.local_collection_id IS NOT NULL
          AND lb.local_collection_id != ''
          AND rc.account_name = ?
      ''', [loginName ?? '']);
      final Set<String> remoteProvisionedLocalIds = {
        for (final row in remoteProvisionedRows) row['local_collection_id'].toString(),
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
          isSubscription: calendar.isSubscription ?? false,
          subscriptionUrl: calendar.subscriptionUrl,
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
      debugPrint('[ERROR] Failed to load local calendars: $e');
      Get.snackbar('Error', 'Failed to load local calendars');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> linkCalendar(
    LocalCalendarItem item,
    bool linkRequested, {
    bool returnToCalendarListAfterConnect = false,
  }) async {
    if (connectingCalendarIds.contains(item.id)) {
      return;
    }

    connectingCalendarIds.add(item.id);
    final bool previousConnectionState = item.isConnected;
    if (linkRequested) {
      item.isConnected = true;
    }
    calendarGroups.refresh();

    try {
      final db = await DatabaseHelper.instance.database;

      String? remotePath;
      String? newRemoteOriginKey;
      if (linkRequested) {
        final List<Map<String, dynamic>> existingRows = await db.rawQuery('''
          SELECT rc.remote_path
          FROM local_bindings lb
          INNER JOIN remote_collections rc ON rc.id = lb.remote_collection_id
          WHERE lb.local_collection_id = ?
          LIMIT 1
        ''', [item.id]);

        final String existingRemotePath = existingRows.isNotEmpty
            ? (existingRows.first['remote_path']?.toString() ?? '')
            : '';

        if (existingRemotePath.isNotEmpty) {
          remotePath = existingRemotePath;
        } else {
          final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
          if (loginName == null || loginName.isEmpty) {
            throw Exception('Not logged in to Calee');
          }

          final List<Map<String, dynamic>> reuseCandidates = await db.rawQuery('''
            SELECT rc.id, rc.remote_path, rc.display_name, rc.origin_key
            FROM remote_collections rc
            INNER JOIN collection_states cs ON cs.remote_collection_id = rc.id
            LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
            WHERE rc.account_name = ?
              AND rc.collection_type = 'calendar'
              AND rc.origin_kind = 0
              AND cs.sync_gate_reason = ?
              AND lb.id IS NULL
          ''', [loginName, SyncGateReason.relinkRequired]);

          final List<_RankedReuseCandidate> rankedCandidates = reuseCandidates
              .map((candidate) => _RankedReuseCandidate(
                    raw: candidate,
                    providerHintScore: _scoreCandidateProviderHint(candidate, item),
                  ))
              .toList()
            ..sort((a, b) => b.providerHintScore.compareTo(a.providerHintScore));

          for (final ranked in rankedCandidates) {
            final Map<String, dynamic> candidate = ranked.raw;
            final String candidatePath = (candidate['remote_path'] ?? '').toString();
            if (candidatePath.isEmpty) {
              continue;
            }

            await db.update(
              'collection_states',
              {
                'sync_gate_reason': SyncGateReason.relinkVerifying,
                'updated_at': DateTime.now().millisecondsSinceEpoch,
              },
              where: 'remote_collection_id = ?',
              whereArgs: [candidate['id']],
            );

            try {
              final RelinkVerificationResult verifyResult = await _relinkVerifier.verify(
                remotePath: candidatePath,
                localCalendarId: item.id,
              );

              if (verifyResult.isIndeterminate) {
                await db.update(
                  'collection_states',
                  {
                    'sync_gate_reason': SyncGateReason.relinkRequired,
                    'updated_at': DateTime.now().millisecondsSinceEpoch,
                  },
                  where: 'remote_collection_id = ?',
                  whereArgs: [candidate['id']],
                );
                debugPrint('[RelinkVerifier] verify_failed_transient for candidate=${candidate['id']}');
                continue;
              }

              if (!verifyResult.passed) {
                await db.update(
                  'collection_states',
                  {
                    'sync_gate_reason': SyncGateReason.relinkMismatch,
                    'updated_at': DateTime.now().millisecondsSinceEpoch,
                  },
                  where: 'remote_collection_id = ?',
                  whereArgs: [candidate['id']],
                );
                continue;
              }

              remotePath = candidatePath;
              await db.update(
                'collection_states',
                {
                  'sync_gate_reason': null,
                  'updated_at': DateTime.now().millisecondsSinceEpoch,
                },
                where: 'remote_collection_id = ?',
                whereArgs: [candidate['id']],
              );

              break;
            } catch (e) {
              await db.update(
                'collection_states',
                {
                  'sync_gate_reason': SyncGateReason.relinkRequired,
                  'updated_at': DateTime.now().millisecondsSinceEpoch,
                },
                where: 'remote_collection_id = ?',
                whereArgs: [candidate['id']],
              );
              debugPrint('[RelinkVerifier] verify_failed_transient for candidate=${candidate['id']}: $e');
              continue;
            }
          }

          if (remotePath == null || remotePath.isEmpty) {
            final bool dangerConfirmed = await _confirmDangerousRemoteCreate(item);
            if (!dangerConfirmed) {
              throw Exception('Remote creation cancelled by user');
            }

            if (item.isSubscription) {
              final String? sourceUrl = item.subscriptionUrl?.trim();
              if (sourceUrl == null || sourceUrl.isEmpty) {
                throw Exception('Subscription URL is unavailable for this local calendar');
              }

              newRemoteOriginKey = const Uuid().v4();
              final String subscriptionCalendarId =
                  'sub_${item.id}_${DateTime.now().millisecondsSinceEpoch}';
              remotePath = await _caleeService.subscribeRemotePublicIcs(
                userId: loginName,
                calendarName: item.name,
                calendarId: subscriptionCalendarId,
                icsUrl: sourceUrl,
              );
            } else {
              newRemoteOriginKey = const Uuid().v4();
              final String cloudCalendarId =
                  'local_${item.id}_${DateTime.now().millisecondsSinceEpoch}';
              remotePath = await _caleeService.createRemoteCalendar(
                userId: loginName,
                calendarName: item.name,
                calendarId: cloudCalendarId,
                color: item.color,
                origin: 'local',
                originKey: newRemoteOriginKey,
              );
            }

            if (remotePath == null || remotePath.isEmpty) {
              throw Exception(
                item.isSubscription
                    ? 'Failed to create remote subscription'
                    : 'Failed to create remote calendar',
              );
            }
          }
        }
      }

      final String accountName =
          MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? item.accountName;
      int? remoteCollectionId;

      if (linkRequested) {
        if (remotePath == null || remotePath.isEmpty) {
          throw Exception('Missing remote path while linking calendar');
        }

        final List<Map<String, dynamic>> remoteRows = await db.query(
          'remote_collections',
          columns: ['id'],
          where: 'account_name = ? AND collection_type = ? AND remote_path = ?',
          whereArgs: [accountName, 'calendar', remotePath],
          limit: 1,
        );

        if (remoteRows.isNotEmpty) {
          remoteCollectionId = remoteRows.first['id'] as int;
          final Map<String, dynamic> remoteCollectionUpdates = {
            'display_name': item.name,
            'account_name': accountName,
            'color': item.color,
            'sync_mode': 0,
            'origin_kind': 0,
            'is_subscription': item.isSubscription ? 1 : 0,
            'subscription_url': item.subscriptionUrl,
            'remote_path': remotePath,
          };
          if (newRemoteOriginKey != null && newRemoteOriginKey.isNotEmpty) {
            remoteCollectionUpdates['origin_key'] = newRemoteOriginKey;
          }
          await db.update(
            'remote_collections',
            remoteCollectionUpdates,
            where: 'id = ?',
            whereArgs: [remoteCollectionId],
          );
        } else {
          remoteCollectionId = await db.insert('remote_collections', {
            'account_name': accountName,
            'collection_type': 'calendar',
            'display_name': item.name,
            'color': item.color,
            'sync_mode': 0,
            'origin_kind': 0,
            'is_subscription': item.isSubscription ? 1 : 0,
            'subscription_url': item.subscriptionUrl,
            'remote_path': remotePath,
            'origin_key': newRemoteOriginKey,
          });
        }

        final String localCollectionId = (item.id ?? '').trim();
        if (localCollectionId.isEmpty || localCollectionId.toLowerCase() == 'null') {
          throw Exception('Invalid local calendar id while linking calendar');
        }

        final int now = DateTime.now().millisecondsSinceEpoch;
        await db.insert(
          'local_bindings',
          {
            'remote_collection_id': remoteCollectionId,
            'local_collection_id': localCollectionId,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        await db.insert(
          'collection_states',
          {
            'remote_collection_id': remoteCollectionId,
            'sync_gate_reason': null,
            'is_enabled': 1,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await db.update(
          'collection_states',
          {
            'sync_gate_reason': null,
            'is_enabled': 1,
            'updated_at': now,
          },
          where: 'remote_collection_id = ?',
          whereArgs: [remoteCollectionId],
        );
      } else {
        await db.update(
          'remote_collections',
          {
            'display_name': item.name,
            'account_name': accountName,
            'color': item.color,
            'sync_mode': 0,
            'is_subscription': item.isSubscription ? 1 : 0,
            'subscription_url': item.subscriptionUrl,
          },
          where: 'id IN (SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?)',
          whereArgs: [item.id],
        );
      }

      if (linkRequested && returnToCalendarListAfterConnect) {
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
      debugPrint('[ERROR] Failed to update local calendar switch: $e');
      Get.snackbar('Error', 'Unable to update calendar link state');
    } finally {
      connectingCalendarIds.remove(item.id);
    }
  }


  int _scoreCandidateProviderHint(Map<String, dynamic> candidate, LocalCalendarItem item) {
    int score = 0;
    final String displayName = (candidate['display_name'] ?? '').toString().trim().toLowerCase();
    final String localName = item.name.trim().toLowerCase();
    if (displayName.isNotEmpty && localName.isNotEmpty) {
      if (displayName == localName) {
        score += 50;
      } else if (displayName.contains(localName) || localName.contains(displayName)) {
        score += 35;
      }
    }

    final String providerCorpus = [
      (item.accountType ?? '').toLowerCase(),
      item.accountName.toLowerCase(),
      (candidate['origin_key'] ?? '').toString().toLowerCase(),
      (candidate['remote_path'] ?? '').toString().toLowerCase(),
    ].join(' ');

    if (providerCorpus.contains('google')) {
      score += 25;
    } else if (providerCorpus.contains('icloud') || providerCorpus.contains('apple')) {
      score += 25;
    } else if (providerCorpus.contains('outlook') || providerCorpus.contains('microsoft')) {
      score += 25;
    }

    if ((candidate['remote_path'] ?? '').toString().toLowerCase().contains(item.id.toLowerCase())) {
      score += 25;
    }

    return score.clamp(0, 100);
  }

  Future<bool> _confirmDangerousRemoteCreate(LocalCalendarItem item) async {
    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Create remote calendar?'),
        content: Text(
          'We could not find a matching remote calendar for "${item.name}". '
          'You can still create one now and manage it anytime in settings. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<bool>(result: false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Get.back<bool>(result: true),
            child: const Text('Create remote calendar'),
          ),
        ],
      ),
      barrierDismissible: false,
    );
    return confirmed == true;
  }

  Future<void> _refreshMainCalendarList() async {
    if (!Get.isRegistered<CalendarPageController>()) {
      return;
    }

    final CalendarPageController dashboardController = Get.find<CalendarPageController>();
    await dashboardController.reloadCalendars();
  }
}

class _RankedReuseCandidate {
  final Map<String, dynamic> raw;
  final int providerHintScore;

  const _RankedReuseCandidate({required this.raw, required this.providerHintScore});
}
