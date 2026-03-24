import '../../common/app_constant.dart';
import '../../common/utils/EventParsedUtils.dart';
import '../../common/utils/UidGenerator.dart';
import '../../common/utils/mmkv_utils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../data/database_helper.dart';
import '../../data/sync_repository.dart';
import '../../entity/SyncContext.dart';
import '../../entity/SyncSummary.dart';
import '../../entity/sync_run_record.dart';
import '../../services/calee_auth_service.dart';
import '../../services/calee_server_service.dart';
import '../SyncEnum.dart';
import '../sync_gate_reason.dart';
import '../sync_run_telemetry.dart';
import 'package:sqflite/sqflite.dart';

abstract class SyncStrategy {
  static const int massDeletionAbsoluteThreshold = 10;

  final SyncRepository repo = SyncRepository();
  final CaleeServerService nc = CaleeServerService();
  final NativeCalendarApi nativeApi = NativeCalendarApi();
  late final LocalItemGateway localGateway = NativeLocalItemGateway(nativeApi);
  late final RemoteItemGateway remoteGateway = CaleeRemoteItemGateway(nc);
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

  Future<LocalEventsSnapshot> loadLocalEvents(
    String localCalendarId, {
    required int rangeStartMs,
    required int rangeEndMs,
  }) async {
    final events = await localGateway.getEvents(localCalendarId, rangeStartMs, rangeEndMs);
    return LocalEventsSnapshot(
      events: events,
      rangeStartMs: rangeStartMs,
      rangeEndMs: rangeEndMs,
      canInferDeletesFromLocalAbsence: false,
    );
  }

  AdaptiveLocalFetchWindow computeAdaptiveLocalFetchWindow({
    required List<Map<String, dynamic>> remoteEvents,
    required List<Map<String, dynamic>> mappedRecords,
    DateTime? now,
  }) {
    return _computeAdaptiveLocalFetchWindow(
      remoteEvents: remoteEvents,
      mappedRecords: mappedRecords,
      now: now,
    );
  }

  AdaptiveLocalFetchWindow _computeAdaptiveLocalFetchWindow({
    required List<Map<String, dynamic>> remoteEvents,
    required List<Map<String, dynamic>> mappedRecords,
    DateTime? now,
  }) {
    const int paddingMs = 1000 * 60 * 60 * 24 * 30; // 30 days
    const int clampSpanMs = 1000 * 60 * 60 * 24 * 365 * 8; // 8 years
    const int fallbackPastMs = 1000 * 60 * 60 * 24 * 365 * 2; // 2 years
    const int fallbackFutureMs = 1000 * 60 * 60 * 24 * 365 * 3; // 3 years

    final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final List<int> timestamps = [];

    void addIfPositive(dynamic value) {
      final int? parsed = value is int ? value : int.tryParse((value ?? '').toString());
      if (parsed != null && parsed > 0) {
        timestamps.add(parsed);
      }
    }

    for (final event in remoteEvents) {
      addIfPositive(event['dtstart']);
      addIfPositive(event['dtend']);
    }
    for (final mapping in mappedRecords) {
      addIfPositive(mapping['dtstart']);
      addIfPositive(mapping['dtend']);
    }

    if (timestamps.isEmpty) {
      return AdaptiveLocalFetchWindow(
        rangeStartMs: nowMs - fallbackPastMs,
        rangeEndMs: nowMs + fallbackFutureMs,
      );
    }

    int minTs = timestamps.reduce((a, b) => a < b ? a : b);
    int maxTs = timestamps.reduce((a, b) => a > b ? a : b);

    minTs -= paddingMs;
    maxTs += paddingMs;

    if (maxTs <= minTs) {
      maxTs = minTs + (1000 * 60 * 60 * 24);
    }

    final int span = maxTs - minTs;
    if (span > clampSpanMs) {
      final int center = minTs + (span ~/ 2);
      minTs = center - (clampSpanMs ~/ 2);
      maxTs = center + (clampSpanMs ~/ 2);
    }

    return AdaptiveLocalFetchWindow(
      rangeStartMs: minTs,
      rangeEndMs: maxTs,
    );
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

    final String? localEventId = await localGateway.createOrUpdateEvent(
      calendarId: localCalendarId,
      title: eventData.summary,
      start: eventData.dtstart,
      end: eventData.dtend,
      uid: eventData.uid,
      notes: eventData.description,
      eventId: existingLocalId,
    );

    if (localEventId == null) {
      return null;
    }

    return RemotePullResult(
      uid: eventData.uid,
      localEventId: localEventId,
      summary: eventData.summary,
      description: eventData.description,
      dtstart: eventData.dtstart,
      dtend: eventData.dtend,
    );
  }

  Future<RemotePushResult?> pushLocalEventToRemote({
    required PlatformItem local,
    required String remotePath,
    required String localCalendarId,
    Map<String, dynamic>? remoteSnapshot,
    String? targetRemoteHref,
  }) async {
    if (loginName == null || loginName!.isEmpty) {
      return null;
    }

    String uid = (local.uid ?? '').trim();
    if (uid.isEmpty) {
      uid = CaleeUid.generate();
      await localGateway.createOrUpdateEvent(
        calendarId: localCalendarId,
        eventId: local.localId,
        uid: uid,
        title: local.title ?? 'Untitled',
        start: local.startTime ?? 0,
        end: local.endTime ?? 0,
        notes: local.notes,
      );
    }

    final String? newEtag = await remoteGateway.uploadEventData(
      userId: loginName!,
      calendarPath: remotePath,
      uid: uid,
      title: local.title ?? 'Untitled',
      description: local.notes,
      location: remoteSnapshot?['location']?.toString(),
      url: remoteSnapshot?['url']?.toString(),
      recurrenceId: remoteSnapshot?['recurrence_id']?.toString(),
      rrule: remoteSnapshot?['rrule']?.toString(),
      created: remoteSnapshot?['created']?.toString(),
      lastModified: remoteSnapshot?['last_modified']?.toString(),
      parseSource: remoteSnapshot?['parse_source']?.toString(),
      dtstartMeta: remoteSnapshot?['dtstart_meta'] as Map<String, dynamic>?,
      dtendMeta: remoteSnapshot?['dtend_meta'] as Map<String, dynamic>?,
      start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0),
      end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0),
      targetEventPath: targetRemoteHref,
    );

    if (newEtag == null) {
      return null;
    }

    final String normalizedRemotePath = remotePath.endsWith('/') ? remotePath : '$remotePath/';
    final String remoteHref = (targetRemoteHref != null && targetRemoteHref.trim().isNotEmpty)
        ? targetRemoteHref.trim()
        : '${normalizedRemotePath}$uid.ics';
    return RemotePushResult(
      uid: uid,
      etag: normalizeRemoteToken(newEtag),
      remoteHref: remoteHref,
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

  Future<_RepairResult> repairDuplicateMappings(
    Database db,
    int remoteCollectionId,
    List<Map<String, dynamic>> mappedRecords,
  ) async {
    final Map<String, List<Map<String, dynamic>>> byRemoteUid = {};
    final Map<String, List<Map<String, dynamic>>> byLocalId = {};

    for (final r in mappedRecords) {
      final uid = r['remote_uid']?.toString() ?? '';
      final localId = r['local_item_id']?.toString() ?? '';
      if (uid.isNotEmpty) byRemoteUid.putIfAbsent(uid, () => []).add(r);
      if (localId.isNotEmpty) byLocalId.putIfAbsent(localId, () => []).add(r);
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
    }

    for (final entry in byLocalId.entries) {
      if (entry.value.length <= 1) continue;
      final winner = pickWinner(entry.value);
      for (final r in entry.value) {
        if (r['id'] != winner['id']) toDeleteIds.add(r['id'] as int);
      }
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

  Future<void> runUnifiedSync(
    SyncContext ctx,
    SyncSummary summary, {
    required UnifiedSyncMode mode,
    bool bootstrap = false,
  }) async {
    final db = await dbHelper.database;
    final String localCalendarId = ctx.localCalendarId;
    final int remoteCollectionId = ctx.remoteCollectionId;
    final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;
    final int bindingRole = (ctx.extra['binding_role'] as int?) ?? SyncBindingRole.mirror;
    final String? syncGateReason = ctx.extra['sync_gate_reason']?.toString();
    final bool safeFirstSync = syncGateReason == SyncGateReason.safeFirstSync;

    final snapshot = await remoteGateway.fetchUnifiedEventsSnapshot(
      calendarPath: ctx.remotePath,
      isSubscription: ctx.isSubscription ?? false,
    );

    final mappedRecords = await db.query(
      'sync_items',
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
    final dedup = await repairDuplicateMappings(db, remoteCollectionId, mappedRecords);

    final adaptiveWindow = computeAdaptiveLocalFetchWindow(
      remoteEvents: snapshot.events,
      mappedRecords: dedup.records,
    );
    final localSnapshot = await loadLocalEvents(
      localCalendarId,
      rangeStartMs: adaptiveWindow.rangeStartMs,
      rangeEndMs: adaptiveWindow.rangeEndMs,
    );
    final localEvents = localSnapshot.events;
    final Map<String, PlatformItem> localByUid = {};
    final Map<String, PlatformItem> localById = mapLocalEventsById(localEvents);
    for (final event in localEvents) {
      final String uid = (event.uid ?? '').trim();
      if (uid.isNotEmpty) localByUid[uid] = event;
    }

    final Map<String, Map<String, dynamic>> mappingByUid = {
      for (final record in dedup.records)
        if ((record['remote_uid']?.toString() ?? '').isNotEmpty) record['remote_uid'].toString(): record,
    };

    final Map<String, Map<String, dynamic>> mappingByLocalId = {
      for (final record in dedup.records)
        if ((record['local_item_id']?.toString() ?? '').isNotEmpty) record['local_item_id'].toString(): record,
    };

    final Map<String, Map<String, dynamic>> remoteByUid = {
      for (final remote in snapshot.events)
        if ((remote['instance_key']?.toString() ?? remote['remote_uid']?.toString() ?? '').trim().isNotEmpty)
          (remote['instance_key']?.toString() ?? remote['remote_uid']?.toString() ?? '').trim(): remote,
    };

    final Set<String> allUids = {
      ...remoteByUid.keys,
      ...mappingByUid.keys,
      ...localByUid.keys,
      ...{
        for (final local in localEvents)
          if ((local.uid ?? '').trim().isEmpty && mappingByLocalId[local.localId ?? ''] != null)
            mappingByLocalId[local.localId ?? '']!['remote_uid'].toString(),
      },
    };

    final rules = UnifiedModeRules.forMode(mode);

    final bool remoteTrusted = snapshot.fetchSucceeded &&
        (snapshot.statusCode == 200 || snapshot.statusCode == 207);
    final bool canDeleteRemoteFromMissingLocal = localSnapshot.canInferDeletesFromLocalAbsence;
    final bool canDeleteLocalFromMissingRemote = remoteTrusted;

    final List<_PlannedAction> plans = [];
    for (final uid in allUids) {
      final remote = remoteByUid[uid];
      final mapping = mappingByUid[uid];
      final PlatformItem? local = localByUid[uid] ??
          (mapping != null ? localById[mapping['local_item_id']?.toString() ?? ''] : null);

      final action = _decideCanonicalAction(
        uid: uid,
        remote: remote,
        mapping: mapping,
        local: local,
        bindingRole: bindingRole,
        rules: rules,
        bootstrap: bootstrap,
        canDeleteRemoteFromMissingLocal: canDeleteRemoteFromMissingLocal,
        canDeleteLocalFromMissingRemote: canDeleteLocalFromMissingRemote,
      );
      plans.add(_PlannedAction(
        uid: uid,
        action: action,
        remote: remote,
        mapping: mapping,
        local: local,
        operations: _buildCanonicalOperations(
          uid: uid,
          action: action,
          remote: remote,
          mapping: mapping,
          local: local,
        ),
      ));
    }

    final List<_CanonicalOperation> allOperations = plans.expand((p) => p.operations).toList();
    final int localDeleteCandidates = allOperations.where((o) => o.type == _CanonicalOperationType.localDelete).length;
    final int remoteDeleteCandidates = allOperations.where((o) => o.type == _CanonicalOperationType.remoteDelete).length;
    final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
    final bool massDeletionSafetyTripped =
        localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
            remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
    final bool blockDeletes = safeFirstSync || (massDeletionSafetyTripped && !allowMassDeletion);

    if (blockDeletes) {
      summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
      summary.telemetry?.onSafetyTriggered(
        ctx: ctx,
        detail: 'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates',
      );
    }

    int createLocal = 0;
    int updateLocal = 0;
    int createRemote = 0;
    int updateRemote = 0;
    int deleteLocal = 0;
    int deleteRemote = 0;
    int skip = 0;

    final Map<String, _ExecutionState> states = {
      for (final plan in plans) plan.uid: _ExecutionState(),
    };

    final nonDeleteOperations = allOperations.where((o) => !o.isDeleteOperation);
    final deleteOperations = allOperations.where((o) => o.isDeleteOperation);

    Future<void> executeOperation(_CanonicalOperation operation) async {
      final state = states.putIfAbsent(operation.uid, () => _ExecutionState());
      switch (operation.type) {
        case _CanonicalOperationType.localCreate:
        case _CanonicalOperationType.localUpdate:
          if (operation.remote == null) {
            skip++;
            return;
          }
          final pulled = await pullRemoteEventToLocal(
            remote: operation.remote!,
            localCalendarId: localCalendarId,
            existingLocalId: operation.local?.localId ?? operation.mapping?['local_item_id']?.toString(),
            isSubscription: ctx.isSubscription ?? false,
          );
          if (pulled == null) {
            skip++;
            return;
          }
          state.pulled = pulled;
          state.mutationSucceeded = true;
          if (operation.type == _CanonicalOperationType.localCreate) {
            createLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.created);
          } else {
            updateLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.updated);
          }
          return;
        case _CanonicalOperationType.remoteCreate:
        case _CanonicalOperationType.remoteUpdate:
          if (operation.local == null) {
            skip++;
            return;
          }
          final pushed = await pushLocalEventToRemote(
            local: operation.local!,
            remotePath: ctx.remotePath,
            localCalendarId: localCalendarId,
            remoteSnapshot: operation.remote,
            targetRemoteHref: operation.type == _CanonicalOperationType.remoteUpdate
                ? (operation.mapping?['remote_href']?.toString() ?? operation.remote?['href']?.toString())
                : null,
          );
          if (pushed == null) {
            skip++;
            return;
          }
          state.pushed = pushed;
          state.mutationSucceeded = true;
          if (operation.type == _CanonicalOperationType.remoteCreate) {
            createRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.created);
          } else {
            updateRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.updated);
          }
          return;
        case _CanonicalOperationType.localDelete:
          if (blockDeletes || !remoteTrusted) {
            skip++;
            return;
          }
          final localId = operation.local?.localId ?? operation.mapping?['local_item_id']?.toString() ?? '';
          if (localId.isNotEmpty) {
            await localGateway.deleteEvent(localId);
          }
          state.mutationSucceeded = true;
          deleteLocal++;
          summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
          return;
        case _CanonicalOperationType.remoteDelete:
          if (blockDeletes || !canDeleteRemoteFromMissingLocal) {
            skip++;
            return;
          }
          final href = operation.mapping?['remote_href']?.toString() ?? operation.remote?['href']?.toString() ?? '';
          if (href.isNotEmpty) {
            await remoteGateway.deleteEvent(eventPath: href);
          }
          state.mutationSucceeded = true;
          deleteRemote++;
          summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.deleted);
          return;
        case _CanonicalOperationType.mappingUpsert:
          if (operation.requireMutationSuccess && !state.mutationSucceeded) {
            return;
          }
          final pulled = state.pulled;
          final pushed = state.pushed;
          final mapping = operation.mapping;
          if (pulled != null) {
            await upsertSyncedItem(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: pulled.uid,
              localItemId: pulled.localEventId,
              etag: normalizeRemoteToken(operation.remote?['etag']),
              lastMtime: DateTime.now().millisecondsSinceEpoch,
              remoteHref: (operation.remote?['href'] ?? '').toString(),
              summary: pulled.summary,
              description: pulled.description,
              dtstart: pulled.dtstart,
              dtend: pulled.dtend,
            );
            return;
          }
          if (pushed != null) {
            await upsertSyncedItem(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: pushed.uid,
              localItemId: operation.local?.localId ?? '',
              etag: pushed.etag,
              lastMtime: pushed.lastMtime,
              remoteHref: pushed.remoteHref,
              summary: operation.local?.title,
              description: operation.local?.notes,
              dtstart: operation.local?.startTime,
              dtend: operation.local?.endTime,
            );
            return;
          }
          if (mapping != null) {
            final Map<String, Object?> updates = {
              'sync_status': SyncItemStatus.synced,
            };
            final String liveLocalId = operation.local?.localId ?? '';
            if (liveLocalId.isNotEmpty) {
              updates['local_item_id'] = liveLocalId;
            }
            await db.update(
              'sync_items',
              updates,
              where: 'id = ?',
              whereArgs: [mapping['id']],
            );
          }
          return;
        case _CanonicalOperationType.mappingDelete:
          if (operation.requireMutationSuccess && !state.mutationSucceeded) {
            return;
          }
          await db.delete(
            'sync_items',
            where: 'remote_collection_id = ? AND remote_uid = ?',
            whereArgs: [remoteCollectionId, operation.uid],
          );
          return;
        case _CanonicalOperationType.skip:
          skip++;
          return;
      }
    }

    for (final operation in nonDeleteOperations) {
      await executeOperation(operation);
    }
    for (final operation in deleteOperations) {
      await executeOperation(operation);
    }

    await db.update(
      'remote_collections',
      {'synced_ctag': ctx.ctag},
      where: 'id = ?',
      whereArgs: [remoteCollectionId],
    );

    if (safeFirstSync) {
      await db.update(
        'collection_states',
        {'sync_gate_reason': null},
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
    }

    if (!blockDeletes) {
      summary.success++;
      summary.recordBindingOutcome(
        bindingId,
        allowMassDeletion ? SyncOutcomeStatus.persistentOverrideEnabled : SyncOutcomeStatus.completedNormally,
      );
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.success,
        snapshotTrustStatus: remoteTrusted ? SnapshotTrustStatus.remote : SnapshotTrustStatus.unknown,
        safetyTriggered: false,
      );
    } else {
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.abortedBySafety,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: true,
        errorCode: SyncErrorCode.safetyStop,
        errorMessage: 'Safety gate blocked deletions',
      );
    }

  }

  List<_CanonicalOperation> _buildCanonicalOperations({
    required String uid,
    required SyncItemAction action,
    required Map<String, dynamic>? remote,
    required Map<String, dynamic>? mapping,
    required PlatformItem? local,
  }) {
    switch (action) {
      case SyncItemAction.createLocal:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.localCreate, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.updateLocal:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.localUpdate, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.createRemote:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.remoteCreate, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.updateRemote:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.remoteUpdate, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.deleteLocal:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.localDelete, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingDelete, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.deleteRemote:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.remoteDelete, uid: uid, remote: remote, mapping: mapping, local: local),
          _CanonicalOperation(type: _CanonicalOperationType.mappingDelete, uid: uid, remote: remote, mapping: mapping, local: local, requireMutationSuccess: true),
        ];
      case SyncItemAction.mappingUpsert:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local),
        ];
      case SyncItemAction.mappingDelete:
        return [
          _CanonicalOperation(type: _CanonicalOperationType.mappingDelete, uid: uid, remote: remote, mapping: mapping, local: local),
        ];
      case SyncItemAction.skip:
        if (mapping != null) {
          return [
            _CanonicalOperation(type: _CanonicalOperationType.mappingUpsert, uid: uid, remote: remote, mapping: mapping, local: local),
          ];
        }
        return [
          _CanonicalOperation(type: _CanonicalOperationType.skip, uid: uid, remote: remote, mapping: mapping, local: local),
        ];
    }
  }


  bool _hasLocalPayloadChanged(PlatformItem local, Map<String, dynamic>? mapping) {
    if (mapping == null) return true;

    final String localTitle = (local.title ?? '').trim();
    final String mappedTitle = (mapping['summary']?.toString() ?? '').trim();
    if (localTitle != mappedTitle) return true;

    final String localNotes = (local.notes ?? '').trim();
    final String mappedNotes = (mapping['description']?.toString() ?? '').trim();
    if (localNotes != mappedNotes) return true;

    final int localStart = local.startTime ?? 0;
    final int mappedStart = (mapping['dtstart'] as int?) ?? 0;
    if (localStart != mappedStart) return true;

    final int localEnd = local.endTime ?? 0;
    final int mappedEnd = (mapping['dtend'] as int?) ?? 0;
    return localEnd != mappedEnd;
  }

  SyncItemAction _decideCanonicalAction({
    required String uid,
    required Map<String, dynamic>? remote,
    required Map<String, dynamic>? mapping,
    required PlatformItem? local,
    required int bindingRole,
    required UnifiedModeRules rules,
    required bool bootstrap,
    required bool canDeleteRemoteFromMissingLocal,
    required bool canDeleteLocalFromMissingRemote,
  }) {
    final bool remoteExists = remote != null;
    final bool localExists = local != null;

    final String remoteToken = normalizeRemoteToken(remote?['etag']);
    final String storedRemoteToken = normalizeRemoteToken(mapping?['last_etag']);
    final int localLastModified = local?.lastModified ?? 0;
    final int storedLocalLastModified = (mapping?['last_mtime'] as int?) ?? 0;

    final bool remoteChanged = remoteExists && (mapping == null || remoteToken != storedRemoteToken);
    final bool localPayloadChanged = localExists && _hasLocalPayloadChanged(local!, mapping);
    final bool localChanged = localExists &&
        (mapping == null || localLastModified > storedLocalLastModified || localPayloadChanged);

    final bool mapped = mapping != null;

    SyncItemAction action;
    if (remoteExists && !localExists) {
      action = mapped ? rules.onRemoteOnlyMapped : rules.onRemoteOnlyUnmapped;
    } else if (!remoteExists && localExists) {
      action = mapped ? rules.onLocalOnlyMapped : rules.onLocalOnlyUnmapped;
    } else if (!remoteExists && !localExists) {
      action = SyncItemAction.skip;
    } else if (!remoteChanged && !localChanged) {
      action = SyncItemAction.skip;
    } else if (remoteChanged && !localChanged) {
      action = rules.onRemoteChanged;
    } else if (!remoteChanged && localChanged) {
      action = rules.onLocalChanged;
    } else {
      action = bindingRole == SyncBindingRole.ownerLink
          ? rules.onConflictLocalWins
          : rules.onConflictRemoteWins;
    }

    if (bootstrap && action == SyncItemAction.skip && localExists && !mapped) {
      action = SyncItemAction.createRemote;
    }

    if (remoteExists &&
        !localExists &&
        mapped &&
        action == SyncItemAction.deleteRemote &&
        !canDeleteRemoteFromMissingLocal) {
      action = SyncItemAction.skip;
    }

    if (!remoteExists &&
        localExists &&
        mapped &&
        action == SyncItemAction.deleteLocal &&
        !canDeleteLocalFromMissingRemote) {
      action = SyncItemAction.skip;
    }

    if (!rules.allowedActions.contains(action)) {
      return SyncItemAction.skip;
    }
    return action;
  }

  SyncItemAction decideCanonicalActionForTesting({
    required String uid,
    required Map<String, dynamic>? remote,
    required Map<String, dynamic>? mapping,
    required PlatformItem? local,
    required int bindingRole,
    required UnifiedModeRules rules,
    required bool bootstrap,
    required bool canDeleteRemoteFromMissingLocal,
    required bool canDeleteLocalFromMissingRemote,
  }) {
    return _decideCanonicalAction(
      uid: uid,
      remote: remote,
      mapping: mapping,
      local: local,
      bindingRole: bindingRole,
      rules: rules,
      bootstrap: bootstrap,
      canDeleteRemoteFromMissingLocal: canDeleteRemoteFromMissingLocal,
      canDeleteLocalFromMissingRemote: canDeleteLocalFromMissingRemote,
    );
  }
}

class RemotePullResult {
  final String uid;
  final String localEventId;
  final String summary;
  final String? description;
  final int? dtstart;
  final int? dtend;

  RemotePullResult({
    required this.uid,
    required this.localEventId,
    required this.summary,
    this.description,
    this.dtstart,
    this.dtend,
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

class LocalEventsSnapshot {
  final List<PlatformItem> events;
  final int rangeStartMs;
  final int rangeEndMs;
  final bool canInferDeletesFromLocalAbsence;

  const LocalEventsSnapshot({
    required this.events,
    required this.rangeStartMs,
    required this.rangeEndMs,
    required this.canInferDeletesFromLocalAbsence,
  });
}

class AdaptiveLocalFetchWindow {
  final int rangeStartMs;
  final int rangeEndMs;

  const AdaptiveLocalFetchWindow({
    required this.rangeStartMs,
    required this.rangeEndMs,
  });
}


abstract class LocalItemGateway {
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end);

  Future<String?> createOrUpdateEvent({
    required String calendarId,
    String? eventId,
    required String uid,
    required String title,
    required int start,
    required int end,
    String? notes,
  });

  Future<bool> deleteEvent(String eventId);
}

class NativeLocalItemGateway extends LocalItemGateway {
  NativeLocalItemGateway(this._nativeApi);

  final NativeCalendarApi _nativeApi;

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async {
    final List<PlatformItem?> items = await _nativeApi.getEvents(localCalendarId, start, end);
    return items.whereType<PlatformItem>().toList();
  }

  @override
  Future<String?> createOrUpdateEvent({
    required String calendarId,
    String? eventId,
    required String uid,
    required String title,
    required int start,
    required int end,
    String? notes,
  }) async {
    return _nativeApi.createOrUpdateEvent(
      CalendarEventRequest(
        calendarId: calendarId,
        eventId: eventId,
        uid: uid,
        title: title,
        start: start,
        end: end,
        notes: notes,
      ),
    );
  }

  @override
  Future<bool> deleteEvent(String eventId) => _nativeApi.deleteEvent(eventId);
}

abstract class RemoteItemGateway {
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  });

  Future<String?> uploadEventData({
    required String userId,
    required String calendarPath,
    required String uid,
    required String title,
    DateTime? start,
    DateTime? end,
    String? description,
    String? location,
    String? url,
    String? recurrenceId,
    String? rrule,
    String? created,
    String? lastModified,
    String? parseSource,
    Map<String, dynamic>? dtstartMeta,
    Map<String, dynamic>? dtendMeta,
    String? targetEventPath,
  });

  Future<bool> deleteEvent({
    required String eventPath,
  });
}

class CaleeRemoteItemGateway extends RemoteItemGateway {
  CaleeRemoteItemGateway(this._service);

  final CaleeServerService _service;

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  }) => _service.fetchUnifiedEventsSnapshot(calendarPath: calendarPath, isSubscription: isSubscription);

  @override
  Future<String?> uploadEventData({
    required String userId,
    required String calendarPath,
    required String uid,
    required String title,
    DateTime? start,
    DateTime? end,
    String? description,
    String? location,
    String? url,
    String? recurrenceId,
    String? rrule,
    String? created,
    String? lastModified,
    String? parseSource,
    Map<String, dynamic>? dtstartMeta,
    Map<String, dynamic>? dtendMeta,
    String? targetEventPath,
  }) => _service.uploadEventData(
        userId: userId,
        calendarPath: calendarPath,
        uid: uid,
        title: title,
        start: start,
        end: end,
        description: description,
        location: location,
        url: url,
        recurrenceId: recurrenceId,
        rrule: rrule,
        created: created,
        lastModified: lastModified,
        parseSource: parseSource,
        dtstartMeta: dtstartMeta,
        dtendMeta: dtendMeta,
        targetEventPath: targetEventPath,
      );

  @override
  Future<bool> deleteEvent({required String eventPath}) => _service.deleteEvent(eventPath: eventPath);
}

enum UnifiedSyncMode { pull, push, bidi }

class UnifiedModeRules {
  final Set<SyncItemAction> allowedActions;
  final SyncItemAction onRemoteOnlyMapped;
  final SyncItemAction onRemoteOnlyUnmapped;
  final SyncItemAction onLocalOnlyMapped;
  final SyncItemAction onLocalOnlyUnmapped;
  final SyncItemAction onRemoteChanged;
  final SyncItemAction onLocalChanged;
  final SyncItemAction onConflictLocalWins;
  final SyncItemAction onConflictRemoteWins;

  const UnifiedModeRules({
    required this.allowedActions,
    required this.onRemoteOnlyMapped,
    required this.onRemoteOnlyUnmapped,
    required this.onLocalOnlyMapped,
    required this.onLocalOnlyUnmapped,
    required this.onRemoteChanged,
    required this.onLocalChanged,
    required this.onConflictLocalWins,
    required this.onConflictRemoteWins,
  });

  static UnifiedModeRules forMode(UnifiedSyncMode mode) {
    switch (mode) {
      case UnifiedSyncMode.pull:
        return const UnifiedModeRules(
          allowedActions: {
            SyncItemAction.createLocal,
            SyncItemAction.updateLocal,
            SyncItemAction.deleteLocal,
            SyncItemAction.skip,
          },
          onRemoteOnlyMapped: SyncItemAction.createLocal,
          onRemoteOnlyUnmapped: SyncItemAction.createLocal,
          onLocalOnlyMapped: SyncItemAction.deleteLocal,
          onLocalOnlyUnmapped: SyncItemAction.skip,
          onRemoteChanged: SyncItemAction.updateLocal,
          onLocalChanged: SyncItemAction.updateLocal,
          onConflictLocalWins: SyncItemAction.updateLocal,
          onConflictRemoteWins: SyncItemAction.updateLocal,
        );
      case UnifiedSyncMode.push:
        return const UnifiedModeRules(
          allowedActions: {
            SyncItemAction.createRemote,
            SyncItemAction.updateRemote,
            SyncItemAction.deleteRemote,
            SyncItemAction.skip,
          },
          // Local side is the source of truth in push mode.
          // If a mapped local event disappears, propagate deletion to remote.
          onRemoteOnlyMapped: SyncItemAction.deleteRemote,
          onRemoteOnlyUnmapped: SyncItemAction.skip,
          onLocalOnlyMapped: SyncItemAction.createRemote,
          onLocalOnlyUnmapped: SyncItemAction.createRemote,
          onRemoteChanged: SyncItemAction.skip,
          onLocalChanged: SyncItemAction.updateRemote,
          onConflictLocalWins: SyncItemAction.updateRemote,
          onConflictRemoteWins: SyncItemAction.updateRemote,
        );
      case UnifiedSyncMode.bidi:
        return const UnifiedModeRules(
          allowedActions: {
            SyncItemAction.createLocal,
            SyncItemAction.updateLocal,
            SyncItemAction.deleteLocal,
            SyncItemAction.createRemote,
            SyncItemAction.updateRemote,
            SyncItemAction.deleteRemote,
            SyncItemAction.skip,
          },
          // In two-way mode, a mapped remote-only record typically means
          // the local event was deleted and should be propagated to remote.
          onRemoteOnlyMapped: SyncItemAction.deleteRemote,
          onRemoteOnlyUnmapped: SyncItemAction.createLocal,
          onLocalOnlyMapped: SyncItemAction.deleteLocal,
          onLocalOnlyUnmapped: SyncItemAction.createRemote,
          onRemoteChanged: SyncItemAction.updateLocal,
          onLocalChanged: SyncItemAction.updateRemote,
          onConflictLocalWins: SyncItemAction.updateRemote,
          onConflictRemoteWins: SyncItemAction.updateLocal,
        );
    }
  }
}

enum _CanonicalOperationType {
  localCreate,
  localUpdate,
  localDelete,
  remoteCreate,
  remoteUpdate,
  remoteDelete,
  mappingUpsert,
  mappingDelete,
  skip,
}

class _CanonicalOperation {
  final _CanonicalOperationType type;
  final String uid;
  final Map<String, dynamic>? remote;
  final Map<String, dynamic>? mapping;
  final PlatformItem? local;
  final bool requireMutationSuccess;

  const _CanonicalOperation({
    required this.type,
    required this.uid,
    required this.remote,
    required this.mapping,
    required this.local,
    this.requireMutationSuccess = false,
  });

  bool get isDeleteOperation =>
      type == _CanonicalOperationType.localDelete ||
      type == _CanonicalOperationType.remoteDelete ||
      type == _CanonicalOperationType.mappingDelete;
}

class _ExecutionState {
  bool mutationSucceeded = false;
  RemotePullResult? pulled;
  RemotePushResult? pushed;
}

class _PlannedAction {
  final String uid;
  final SyncItemAction action;
  final Map<String, dynamic>? remote;
  final Map<String, dynamic>? mapping;
  final PlatformItem? local;
  final List<_CanonicalOperation> operations;

  _PlannedAction({
    required this.uid,
    required this.action,
    required this.remote,
    required this.mapping,
    required this.local,
    required this.operations,
  });
}

class _RepairResult {
  final List<Map<String, dynamic>> records;
  final int removedCount;

  _RepairResult({required this.records, required this.removedCount});
}
