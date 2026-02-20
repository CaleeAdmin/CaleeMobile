import 'package:caleesync/common/utils/UidGenerator.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../common/utils/EventParsedUtils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';

/// TWO_WAY strategy using a deterministic per-item decision matrix.
///
/// Decision inputs: remoteExists/localExists/remoteChanged/localChanged.
/// Conflict resolution: binding origin decides winner (remote pull vs local push).
class FullSyncBidiStrategy extends SyncStrategy {
  static const int _defaultDeletionPolicy = SyncDeletionPolicy.bidirectional;

  String _keyUid(PlatformItem e) {
    final u = (e.uid ?? '').trim();
    if (u.isNotEmpty) return u;
    return 'local_${e.localId}';
  }

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    try {
      if (loginName == null || loginName?.isEmpty == true) return;

      final db = await dbHelper.database;
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;
      final String remotePath = ctx.remotePath;
      final int origin = (ctx.extra['binding_origin'] as int?) ?? SyncBindingOrigin.remote;

      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );

      final _RepairResult dedup = await _repairDuplicateMappings(db, remoteCollectionId, mappedRecords);
      final List<Map<String, dynamic>> records = dedup.records;

      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
      final items = await nativeApi.getEvents(localCalendarId, start, end);
      final Map<String, PlatformItem> localItemsMap = {
        for (var e in items.whereType<PlatformItem>()) _keyUid(e): e
      };

      final Map<String, Map<String, dynamic>> mappingByRemoteUid = {
        for (var r in records)
          if ((r['remote_uid']?.toString() ?? '').isNotEmpty) r['remote_uid'].toString(): r
      };

      final Map<String, Map<String, dynamic>> remoteByUid = {
        for (var r in remoteEvents)
          if ((r['remote_uid']?.toString() ?? '').isNotEmpty) r['remote_uid'].toString(): r
      };

      final Set<String> allUids = {
        ...remoteByUid.keys,
        ...mappingByRemoteUid.keys,
        ...localItemsMap.keys,
      };

      int createLocal = 0;
      int createRemote = 0;
      int pull = 0;
      int push = 0;
      int deleteLocal = 0;
      int deleteRemote = 0;
      int stagedDeleteLocal = 0;
      int skip = 0;
      int conflicts = 0;

      debugPrint('[SYNC_BINDING][id=$remoteCollectionId] mode=TWO_WAY origin=$origin deletionPolicy=$_defaultDeletionPolicy '
          'counts(remote=${remoteByUid.length}, local=${localItemsMap.length}, mapped=${mappingByRemoteUid.length})');

      // Main decision matrix loop: each uid maps to exactly one action.
      for (final uid in allUids) {
        final remote = remoteByUid[uid];
        final mapping = mappingByRemoteUid[uid];
        final local = localItemsMap[uid];

        final bool remoteExists = remote != null;
        final bool localExists = local != null;

        final String remoteToken = _normalizeRemoteToken(remote?['etag']);
        final String storedRemoteToken = _normalizeRemoteToken(mapping?['last_etag']);
        final int localLastModified = local?.lastModified ?? 0;
        final int storedLocalLastModified = (mapping?['last_mtime'] as int?) ?? 0;

        final bool remoteChanged = remoteExists && (mapping == null || remoteToken != storedRemoteToken);
        final bool localChanged = localExists && (mapping == null || localLastModified > storedLocalLastModified);
        final int status = (mapping?['sync_status'] as int?) ?? SyncItemStatus.synced;

        SyncItemAction action;
        String reason;

        if (remoteExists && !localExists) {
          action = SyncItemAction.createLocal;
          reason = 'remote_exists_local_missing';
        } else if (!remoteExists && localExists) {
          if (_defaultDeletionPolicy == SyncDeletionPolicy.remoteDeleteWins) {
            action = SyncItemAction.deleteLocal;
            reason = 'remote_missing_local_exists_remote_delete_wins';
          } else {
            action = SyncItemAction.deleteRemote;
            reason = 'remote_missing_local_exists_bidirectional_delete';
          }
        } else if (!remoteExists && !localExists) {
          action = SyncItemAction.skip;
          reason = 'neither_exists';
        } else {
          if (!remoteChanged && !localChanged) {
            action = SyncItemAction.skip;
            reason = 'no_change';
          } else if (remoteChanged && !localChanged) {
            action = SyncItemAction.pull;
            reason = 'remote_changed_only';
          } else if (!remoteChanged && localChanged) {
            action = SyncItemAction.push;
            reason = 'local_changed_only';
          } else {
            conflicts++;
            if (origin == SyncBindingOrigin.local) {
              action = SyncItemAction.push;
              reason = 'conflict_origin_local';
            } else {
              action = SyncItemAction.pull;
              reason = 'conflict_origin_remote';
            }
          }
        }

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] action=$action '
            'flags(remoteExists=$remoteExists localExists=$localExists remoteChanged=$remoteChanged localChanged=$localChanged origin=$origin reason=$reason)');

        switch (action) {
          case SyncItemAction.createLocal:
            await _pullFromRemote(remote!, localCalendarId, remoteCollectionId, mapping?['local_item_id']?.toString(), remoteToken, db);
            createLocal++;
            break;
          case SyncItemAction.pull:
            await _pullFromRemote(remote!, localCalendarId, remoteCollectionId, mapping?['local_item_id']?.toString(), remoteToken, db);
            pull++;
            break;
          case SyncItemAction.push:
            await _pushToRemote(local!, remotePath, db, localCalendarId, remoteCollectionId);
            if (mapping == null) {
              createRemote++;
            } else {
              push++;
            }
            break;
          case SyncItemAction.deleteLocal:
            if (mapping == null) {
              if (local != null && local.localId != null) {
                await nativeApi.deleteEvent(local.localId!);
              }
              break;
            }

            if (status != SyncItemStatus.pendingDelete) {
              await db.update(
                'sync_items',
                {'sync_status': SyncItemStatus.pendingDelete},
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
              stagedDeleteLocal++;
              break;
            }

            if (mapping['local_item_id'] != null) {
              await nativeApi.deleteEvent(mapping['local_item_id'].toString());
            } else if (local != null && local.localId != null) {
              await nativeApi.deleteEvent(local.localId!);
            }
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteLocal++;
            break;
          case SyncItemAction.deleteRemote:
            final href = mapping?['remote_href']?.toString() ?? remote?['href']?.toString() ?? '';
            if (href.isNotEmpty) {
              await nc.deleteEvent(eventPath: href);
            }
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteRemote++;
            break;
          case SyncItemAction.skip:
            if (mapping != null && remoteExists && status != SyncItemStatus.synced) {
              await db.update(
                'sync_items',
                {'sync_status': SyncItemStatus.synced},
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
            }
            skip++;
            break;
        }
      }

      summary.success++;
      summary.successLog.add('🔄 双向同步完成: ${ctx.displayName}');
      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal createRemote=$createRemote '
          'pull=$pull push=$push deleteLocal=$deleteLocal stagedDeleteLocal=$stagedDeleteLocal deleteRemote=$deleteRemote skip=$skip conflicts=$conflicts dedupRemoved=${dedup.removedCount}');
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('❌ ${ctx.displayName} 双向同步异常: $e');
    }
  }

  /// Repair duplicate mapping rows to enforce uniqueness invariants.
  ///
  /// Winner is chosen deterministically by structural quality, not "latest" heuristics.
  Future<_RepairResult> _repairDuplicateMappings(
    Database db,
    int remoteCollectionId,
    List<Map<String, dynamic>> mappedRecords,
  ) async {
    final Map<String, List<Map<String, dynamic>>> byRemoteUid = {};
    final Map<String, List<Map<String, dynamic>>> byLocalId = {};

    for (final r in mappedRecords) {
      final uid = r['remote_uid']?.toString() ?? '';
      final localId = r['local_item_id']?.toString() ?? '';
      if (uid.isNotEmpty) {
        byRemoteUid.putIfAbsent(uid, () => []).add(r);
      }
      if (localId.isNotEmpty) {
        byLocalId.putIfAbsent(localId, () => []).add(r);
      }
    }

    final Set<int> toDeleteIds = {};

    Map<String, dynamic> pickWinner(List<Map<String, dynamic>> group) {
      group.sort((a, b) {
        final int aHasLocal = ((a['local_item_id']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        final int bHasLocal = ((b['local_item_id']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        if (aHasLocal != bHasLocal) return bHasLocal.compareTo(aHasLocal);

        final int aHasHref = ((a['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        final int bHasHref = ((b['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        if (aHasHref != bHasHref) return bHasHref.compareTo(aHasHref);

        final int aid = (a['id'] as int?) ?? 0;
        final int bid = (b['id'] as int?) ?? 0;
        return aid.compareTo(bid);
      });
      return group.first;
    }

    for (final entry in byRemoteUid.entries) {
      if (entry.value.length <= 1) continue;
      final winner = pickWinner(entry.value);
      for (final r in entry.value) {
        if (r['id'] != winner['id']) toDeleteIds.add(r['id'] as int);
      }
      debugPrint('[SYNC_DEDUP][binding=$remoteCollectionId] duplicate_remote_uid=${entry.key} count=${entry.value.length} winner=${winner['id']}');
    }

    for (final entry in byLocalId.entries) {
      if (entry.value.length <= 1) continue;
      final winner = pickWinner(entry.value);
      for (final r in entry.value) {
        if (r['id'] != winner['id']) toDeleteIds.add(r['id'] as int);
      }
      debugPrint('[SYNC_DEDUP][binding=$remoteCollectionId] duplicate_local_id=${entry.key} count=${entry.value.length} winner=${winner['id']}');
    }

    for (final id in toDeleteIds) {
      await db.delete('sync_items', where: 'id = ?', whereArgs: [id]);
    }

    final List<Map<String, dynamic>> refreshed = await db.query(
      'sync_items',
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
    return _RepairResult(records: refreshed, removedCount: toDeleteIds.length);
  }

  String _normalizeRemoteToken(dynamic token) => (token ?? '').toString().replaceAll('"', '');

  Future<void> _pullFromRemote(
    Map<String, dynamic> remote,
    String localCalendarId,
    int remoteCollectionId,
    String? localId,
    String remoteToken,
    dynamic db,
  ) async {
    final eventData = await Eventparsedutils.resolveEventData(remote: remote, isSubscription: false);
    if (eventData == null) return;

    final String? newSystemId = await nativeApi.createOrUpdateEvent(CalendarEventRequest(
      calendarId: localCalendarId,
      title: eventData.summary,
      start: eventData.dtstart,
      end: eventData.dtend,
      uid: eventData.uid,
      notes: eventData.description,
      eventId: localId,
    ));

    if (newSystemId != null) {
      await db.insert('sync_items', {
        'remote_uid': eventData.uid,
        'local_item_id': newSystemId,
        'remote_collection_id': remoteCollectionId,
        'last_etag': remoteToken,
        'last_mtime': DateTime.now().millisecondsSinceEpoch,
        'remote_href': remote['href'],
        'sync_status': SyncItemStatus.synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Push local event state to remote CalDAV and persist returned remote token.
  ///
  /// This method is invoked when decision matrix emits PUSH:
  /// - localChanged only
  /// - conflict with origin=LOCAL
  /// - local-only item in TWO_WAY mode (remote create through push)
  Future<void> _pushToRemote(
    PlatformItem local,
    String remotePath,
    dynamic db,
    String localCalendarId,
    int remoteCollectionId,
  ) async {
    var uid = (local.uid ?? '').trim();
    if (uid.isEmpty) {
      uid = CaleeUid.generate();
      await nativeApi.createOrUpdateEvent(CalendarEventRequest(
        calendarId: localCalendarId,
        eventId: local.localId,
        uid: uid,
        title: local.title ?? '无标题',
        start: local.startTime ?? 0,
        end: local.endTime ?? 0,
        notes: local.notes,
      ));
    }

    final String? newEtag = await nc.uploadEventData(
      userId: loginName!,
      calendarPath: remotePath,
      uid: uid,
      title: local.title ?? '无标题',
      start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0),
      end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0),
    );

    if (newEtag != null) {
      await db.insert('sync_items', {
        'remote_uid': uid,
        'local_item_id': local.localId,
        'remote_collection_id': remoteCollectionId,
        'last_etag': _normalizeRemoteToken(newEtag),
        'last_mtime': local.lastModified ?? DateTime.now().millisecondsSinceEpoch,
        'remote_href': "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics",
        'sync_status': SyncItemStatus.synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}

class _RepairResult {
  final List<Map<String, dynamic>> records;
  final int removedCount;

  _RepairResult({required this.records, required this.removedCount});
}
