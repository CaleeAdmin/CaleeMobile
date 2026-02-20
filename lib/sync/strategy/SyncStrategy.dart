import '../../common/app_constant.dart';
import '../../common/utils/EventParsedUtils.dart';
import '../../common/utils/UidGenerator.dart';
import '../../common/utils/mmkv_utils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../data/database_helper.dart';
import '../../data/sync_repository.dart';
import '../../entity/SyncContext.dart';
import '../../entity/SyncSummary.dart';
import '../../services/calee_auth_service.dart';
import '../../services/calee_server_service.dart';
import '../SyncEnum.dart';
import 'package:sqflite/sqflite.dart';

abstract class SyncStrategy {
  static const int massDeletionAbsoluteThreshold = 10;

  final SyncRepository repo = SyncRepository();
  final CaleeServerService nc = CaleeServerService();
  final NativeCalendarApi nativeApi = NativeCalendarApi();
  final CaleeAuthService authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);
  final DatabaseHelper dbHelper = DatabaseHelper.instance;
  final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
  final String? password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

  Future<void> execute(SyncContext ctx, SyncSummary summary);

  SyncItemDecision resolveItemDecision({
    required SyncAction mode,
    required int bindingOrigin,
    required int deletionPolicy,
    required bool hasMapping,
    required bool remoteExists,
    required bool localExists,
    required bool remoteChanged,
    required bool localChanged,
  }) {
    final bool allowPull = mode == SyncAction.fullSyncPull || mode == SyncAction.fullSyncBidi;
    final bool allowPush = mode == SyncAction.fullSyncPush || mode == SyncAction.fullSyncBidi;

    if (remoteExists && !localExists) {
      if (!allowPull) return const SyncItemDecision.noOp(reason: 'pull_not_allowed_for_mode');
      return const SyncItemDecision(intent: SyncItemIntent.create, action: SyncItemAction.createLocal, reason: 'remote_exists_local_missing');
    }

    if (!remoteExists && localExists) {
      final bool preferDeleteLocal = mode == SyncAction.fullSyncPull ||
          (mode == SyncAction.fullSyncBidi && deletionPolicy == SyncDeletionPolicy.remoteDeleteWins);
      if (preferDeleteLocal) {
        return const SyncItemDecision(intent: SyncItemIntent.delete, action: SyncItemAction.deleteLocal, reason: 'remote_missing_local_exists_delete_local');
      }
      if (allowPush) {
        return const SyncItemDecision(intent: SyncItemIntent.delete, action: SyncItemAction.deleteRemote, reason: 'remote_missing_local_exists_delete_remote');
      }
      return const SyncItemDecision.noOp(reason: 'delete_remote_not_allowed_for_mode');
    }

    if (!remoteExists && !localExists) {
      return const SyncItemDecision.noOp(reason: 'neither_exists');
    }

    if (!remoteChanged && !localChanged) {
      return const SyncItemDecision.noOp(reason: 'no_change');
    }

    if (remoteChanged && !localChanged) {
      if (!allowPull) return const SyncItemDecision.noOp(reason: 'pull_not_allowed_for_mode');
      return const SyncItemDecision(intent: SyncItemIntent.update, action: SyncItemAction.pull, reason: 'remote_changed');
    }

    if (!remoteChanged && localChanged) {
      if (!allowPush) return const SyncItemDecision.noOp(reason: 'push_not_allowed_for_mode');
      return SyncItemDecision(
        intent: hasMapping ? SyncItemIntent.update : SyncItemIntent.create,
        action: SyncItemAction.push,
        reason: 'local_changed',
      );
    }

    if (bindingOrigin == SyncBindingOrigin.local && allowPush) {
      return SyncItemDecision(
        intent: hasMapping ? SyncItemIntent.update : SyncItemIntent.create,
        action: SyncItemAction.push,
        reason: 'conflict_origin_local',
      );
    }
    if (allowPull) {
      return const SyncItemDecision(intent: SyncItemIntent.update, action: SyncItemAction.pull, reason: 'conflict_origin_remote');
    }
    return const SyncItemDecision.noOp(reason: 'conflict_no_allowed_write_path');
  }

  Future<List<Map<String, dynamic>>> repairDuplicateMappings(
    Database db,
    int remoteCollectionId,
    List<Map<String, dynamic>> mappedRecords,
  ) async {
    final Map<String, List<Map<String, dynamic>>> byRemoteUid = {};
    for (final row in mappedRecords) {
      final String key = row['remote_uid']?.toString() ?? '';
      if (key.isEmpty) continue;
      byRemoteUid.putIfAbsent(key, () => []).add(row);
    }

    for (final rows in byRemoteUid.values) {
      if (rows.length <= 1) continue;
      rows.sort((a, b) => ((a['id'] as int?) ?? 0).compareTo((b['id'] as int?) ?? 0));
      for (final duplicate in rows.skip(1)) {
        final int? id = duplicate['id'] as int?;
        if (id != null) {
          await db.delete('sync_items', where: 'id = ?', whereArgs: [id]);
        }
      }
    }

    return db.query(
      'sync_items',
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
  }

  String massDeletionKeyForBinding(int bindingId) =>
      '${AppConstant.allowMassDeletionByBindingKeyPrefix}$bindingId';

  bool isMassDeletionOverrideEnabled(int bindingId) {
    if (bindingId <= 0) return false;
    return MMKVUtils.instance.getBool(massDeletionKeyForBinding(bindingId), defaultValue: false) ?? false;
  }

  String normalizeRemoteToken(dynamic token) => (token ?? '').toString().replaceAll('"', '');

  Future<List<PlatformItem>> loadLocalEvents(String localCalendarId) async {
    final int start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
    final int end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
    final List<PlatformItem?> items = await nativeApi.getEvents(localCalendarId, start, end);
    return items.whereType<PlatformItem>().toList();
  }

  Map<String, PlatformItem> mapLocalEventsByUid(List<PlatformItem> localEvents) {
    return {
      for (final event in localEvents)
        if ((event.uid ?? '').trim().isNotEmpty) (event.uid ?? '').trim(): event,
    };
  }

  Map<String, PlatformItem> mapLocalEventsById(List<PlatformItem> localEvents) {
    return {
      for (final event in localEvents)
        if ((event.localId ?? '').isNotEmpty) (event.localId ?? ''): event,
    };
  }

  Future<RemotePullResult?> pullRemoteEventToLocal({
    required Map<String, dynamic> remote,
    required String localCalendarId,
    required String? existingLocalId,
    required bool isSubscription,
  }) async {
    final eventData = await Eventparsedutils.resolveEventData(
      remote: remote,
      isSubscription: isSubscription,
    );
    if (eventData == null) {
      return null;
    }

    final String? localEventId = await nativeApi.createOrUpdateEvent(
      CalendarEventRequest(
        calendarId: localCalendarId,
        title: eventData.summary,
        start: eventData.dtstart,
        end: eventData.dtend,
        uid: eventData.uid,
        notes: eventData.description,
        eventId: existingLocalId,
      ),
    );

    if (localEventId == null) {
      return null;
    }

    return RemotePullResult(
      uid: eventData.uid,
      localEventId: localEventId,
      summary: eventData.summary,
    );
  }

  Future<RemotePushResult?> pushLocalEventToRemote({
    required PlatformItem local,
    required String remotePath,
    required String localCalendarId,
  }) async {
    if (loginName == null || loginName!.isEmpty) {
      return null;
    }

    String uid = (local.uid ?? '').trim();
    if (uid.isEmpty) {
      uid = CaleeUid.generate();
      await nativeApi.createOrUpdateEvent(
        CalendarEventRequest(
          calendarId: localCalendarId,
          eventId: local.localId,
          uid: uid,
          title: local.title ?? 'Untitled',
          start: local.startTime ?? 0,
          end: local.endTime ?? 0,
          notes: local.notes,
        ),
      );
    }

    final String? newEtag = await nc.uploadEventData(
      userId: loginName!,
      calendarPath: remotePath,
      uid: uid,
      title: local.title ?? 'Untitled',
      start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0),
      end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0),
    );

    if (newEtag == null) {
      return null;
    }

    final String normalizedRemotePath = remotePath.endsWith('/') ? remotePath : '$remotePath/';
    return RemotePushResult(
      uid: uid,
      etag: normalizeRemoteToken(newEtag),
      remoteHref: '${normalizedRemotePath}$uid.ics',
      lastMtime: local.lastModified ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> upsertSyncedItem({
    required Database db,
    required int remoteCollectionId,
    required String uid,
    required String localItemId,
    required String etag,
    required int lastMtime,
    required String remoteHref,
    String? summary,
  }) async {
    final payload = {
      'remote_uid': uid,
      'local_item_id': localItemId,
      'remote_collection_id': remoteCollectionId,
      'summary': summary,
      'last_etag': normalizeRemoteToken(etag),
      'last_mtime': lastMtime,
      'remote_href': remoteHref,
      'sync_status': SyncItemStatus.synced,
    };

    final bool hasLocalItemId = localItemId.trim().isNotEmpty;
    final String whereClause = hasLocalItemId
        ? 'remote_collection_id = ? AND (remote_uid = ? OR local_item_id = ?)'
        : 'remote_collection_id = ? AND remote_uid = ?';
    final List<dynamic> whereArgs = hasLocalItemId
        ? [remoteCollectionId, uid, localItemId]
        : [remoteCollectionId, uid];

    final List<Map<String, dynamic>> matches = await db.query(
      'sync_items',
      columns: ['id', 'remote_href'],
      where: whereClause,
      whereArgs: whereArgs,
    );

    if (matches.isEmpty) {
      await db.insert(
        'sync_items',
        payload,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }

    matches.sort((a, b) {
      final int aHasHref = ((a['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
      final int bHasHref = ((b['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
      if (aHasHref != bHasHref) {
        return bHasHref.compareTo(aHasHref);
      }
      final int aid = (a['id'] as int?) ?? 0;
      final int bid = (b['id'] as int?) ?? 0;
      return aid.compareTo(bid);
    });

    final int winnerId = (matches.first['id'] as int?) ?? 0;
    await db.update('sync_items', payload, where: 'id = ?', whereArgs: [winnerId]);

    if (matches.length > 1) {
      for (final row in matches.skip(1)) {
        final int? duplicateId = row['id'] as int?;
        if (duplicateId == null) continue;
        await db.delete('sync_items', where: 'id = ?', whereArgs: [duplicateId]);
      }
    }
  }
}

enum SyncItemIntent { create, update, delete, noOp }

class SyncItemDecision {
  final SyncItemIntent intent;
  final SyncItemAction action;
  final String reason;

  const SyncItemDecision({
    required this.intent,
    required this.action,
    required this.reason,
  });

  const SyncItemDecision.noOp({required this.reason})
      : intent = SyncItemIntent.noOp,
        action = SyncItemAction.skip;
}

class RemotePullResult {
  final String uid;
  final String localEventId;
  final String summary;

  RemotePullResult({
    required this.uid,
    required this.localEventId,
    required this.summary,
  });
}

class RemotePushResult {
  final String uid;
  final String etag;
  final String remoteHref;
  final int lastMtime;

  RemotePushResult({
    required this.uid,
    required this.etag,
    required this.remoteHref,
    required this.lastMtime,
  });
}
