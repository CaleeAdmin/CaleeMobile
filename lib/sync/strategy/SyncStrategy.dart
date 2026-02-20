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
    String? description,
    int? dtstart,
    int? dtend,
  }) async {
    final payload = {
      'remote_uid': uid,
      'local_item_id': localItemId,
      'remote_collection_id': remoteCollectionId,
      'summary': summary,
      'description': description,
      'dtstart': dtstart,
      'dtend': dtend,
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
