import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

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
      final String? newCtag = ctx.ctag;
      final int origin = (ctx.extra['binding_origin'] as int?) ?? SyncBindingOrigin.remote;
      final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;

      final UnifiedEventsSnapshot snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final List<Map<String, dynamic>> remoteEvents = snapshot.events;

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );

      final _RepairResult dedup = await _repairDuplicateMappings(db, remoteCollectionId, mappedRecords);
      final List<Map<String, dynamic>> records = dedup.records;

      final localEvents = await loadLocalEvents(localCalendarId);
      final Map<String, PlatformItem> localItemsMap = {
        for (final e in localEvents) _keyUid(e): e,
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

      final int mappedCount = mappingByRemoteUid.length;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool suspiciousEmptyLocalFetch = localItemsMap.isEmpty && mappedCount > 0;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded &&
          (snapshot.statusCode == 200 || snapshot.statusCode == 207) &&
          (newCtag ?? '').isNotEmpty &&
          !suspiciousEmptyRemoteFetch;
      final bool localSnapshotTrusted = !suspiciousEmptyLocalFetch;

      int localDeleteCandidates = 0;
      int remoteDeleteCandidates = 0;
      for (final uid in allUids) {
        final remoteExists = remoteByUid[uid] != null;
        final localExists = localItemsMap[uid] != null;
        if (!remoteExists && localExists) {
          if (_defaultDeletionPolicy == SyncDeletionPolicy.remoteDeleteWins) {
            localDeleteCandidates++;
          } else {
            remoteDeleteCandidates++;
          }
        }
      }

      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
          remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;

      if (!remoteSnapshotTrusted || !localSnapshotTrusted) {
        debugPrint('[SYNC_SAFETY][binding=$remoteCollectionId] TWO_WAY untrusted snapshot; block delete actions '
            '(remoteTrusted=$remoteSnapshotTrusted, localTrusted=$localSnapshotTrusted, status=${snapshot.statusCode}, fetchSucceeded=${snapshot.fetchSucceeded})');
      }
      if (blockDeletesBySafetyGate) {
        debugPrint('[SYNC_SAFETY][binding=$remoteCollectionId] aborted by safety gate '
            '(localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.errorLog.add('🛑 ${ctx.displayName} Safety gate blocked deletions (localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
      }

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

        final String remoteToken = normalizeRemoteToken(remote?['etag']);
        final String storedRemoteToken = normalizeRemoteToken(mapping?['last_etag']);
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
            if (blockDeletesBySafetyGate || !remoteSnapshotTrusted || !localSnapshotTrusted) {
              break;
            }

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
            if (blockDeletesBySafetyGate || !remoteSnapshotTrusted || !localSnapshotTrusted) {
              break;
            }
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

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        if (allowMassDeletion) {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.persistentOverrideEnabled);
          summary.successLog.add('⚠️ ${ctx.displayName} Persistent override enabled (dangerous mode)');
        } else {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.completedNormally);
          summary.successLog.add('🔄 ${ctx.displayName} Completed normally');
        }
      }
      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal createRemote=$createRemote '
          'pull=$pull push=$push deleteLocal=$deleteLocal stagedDeleteLocal=$stagedDeleteLocal deleteRemote=$deleteRemote skip=$skip '
          'conflicts=$conflicts dedupRemoved=${dedup.removedCount} remoteSnapshotTrusted=$remoteSnapshotTrusted localSnapshotTrusted=$localSnapshotTrusted '
          'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates safetyAborted=$blockDeletesBySafetyGate allowMassDeletion=$allowMassDeletion status=${snapshot.statusCode}');
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

  Future<void> _pullFromRemote(
    Map<String, dynamic> remote,
    String localCalendarId,
    int remoteCollectionId,
    String? localId,
    String remoteToken,
    Database db,
  ) async {
    final RemotePullResult? pulled = await pullRemoteEventToLocal(
      remote: remote,
      localCalendarId: localCalendarId,
      existingLocalId: localId,
      isSubscription: false,
    );
    if (pulled == null) {
      return;
    }

    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: pulled.uid,
      localItemId: pulled.localEventId,
      etag: remoteToken,
      lastMtime: DateTime.now().millisecondsSinceEpoch,
      remoteHref: (remote['href'] ?? '').toString(),
      summary: pulled.summary,
    );
  }

  Future<void> _pushToRemote(
    PlatformItem local,
    String remotePath,
    Database db,
    String localCalendarId,
    int remoteCollectionId,
  ) async {
    final RemotePushResult? pushed = await pushLocalEventToRemote(
      local: local,
      remotePath: remotePath,
      localCalendarId: localCalendarId,
    );
    if (pushed == null) {
      return;
    }

    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: pushed.uid,
      localItemId: local.localId,
      etag: pushed.etag,
      lastMtime: pushed.lastMtime,
      remoteHref: pushed.remoteHref,
    );
  }
}

class _RepairResult {
  final List<Map<String, dynamic>> records;
  final int removedCount;

  _RepairResult({required this.records, required this.removedCount});
}
