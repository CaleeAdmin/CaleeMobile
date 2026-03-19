import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';
import '../data/database_helper.dart';
import '../entity/SyncContext.dart';
import '../services/calee_server_service.dart';
import 'SyncEnum.dart';
import 'force_sync_registry.dart';
import 'sync_gate_reason.dart';

class SyncItemPlanner {
  SyncItemPlanner({
    DatabaseHelper? dbHelper,
    NativeCalendarApi? nativeApi,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _native = nativeApi ?? NativeCalendarApi();

  final DatabaseHelper _dbHelper;
  final NativeCalendarApi _native;

  Future<List<SyncContext>> generateSyncItems(
    String accountName,
    List<Map<String, dynamic>> remoteResults,
  ) async {
    final db = await _dbHelper.database;

    final List<Map<String, dynamic>> collectionRows = await db.rawQuery('''
      SELECT
        rc.id,
        rc.account_name,
        rc.remote_path,
        rc.display_name,
        rc.color,
        rc.synced_ctag,
        rc.sync_mode,
        cs.is_enabled AS state_is_enabled,
        rc.is_subscription,
        rc.origin_kind,
        lb.id AS binding_id,
        lb.local_collection_id,
        cs.sync_gate_reason
      FROM remote_collections rc
      LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      LEFT JOIN collection_states cs ON cs.remote_collection_id = rc.id
      WHERE rc.account_name = ?
        AND rc.collection_type = 'calendar'
    ''', [accountName]);

    final remoteMap = {
      for (final r in remoteResults)
        if ((r['remote_path']?.toString() ?? '').isNotEmpty)
          CaleeServerService.normalizeRemotePath(r['remote_path'].toString()): r,
    };

    final List<PlatformCalendar?> nativeCalendars = await _native.getCalendars();
    final Map<String, PlatformCalendar> nativeCalendarsById = {
      for (final PlatformCalendar calendar in nativeCalendars.whereType<PlatformCalendar>())
        if ((calendar.id ?? '').isNotEmpty) calendar.id!: calendar,
    };

    final bool hasValidAuth = _hasValidAuthContext();

    final List<SyncContext> contexts = [];
    for (final local in collectionRows) {
      final SyncContext? context = await _buildSyncItemContext(
        db: db,
        local: local,
        remoteMap: remoteMap,
        nativeCalendarsById: nativeCalendarsById,
        hasValidAuth: hasValidAuth,
      );
      if (context != null) {
        contexts.add(context);
      }
    }

    return contexts;
  }

  Future<SyncContext?> _buildSyncItemContext({
    required Database db,
    required Map<String, dynamic> local,
    required Map<String, dynamic> remoteMap,
    required Map<String, PlatformCalendar> nativeCalendarsById,
    required bool hasValidAuth,
  }) async {
    final String path = CaleeServerService.normalizeRemotePath(local['remote_path']?.toString() ?? '');
    final Map<String, dynamic>? remote = remoteMap[path];
    final int remoteCollectionId = (local['id'] as int?) ?? 0;
    final int isEnabled = (local['state_is_enabled'] as int?) ?? 0;
    final int originKind = (local['origin_kind'] as int?) ?? SyncBindingOrigin.remote;

    if (isEnabled != 1) {
      return null;
    }

    final bool forceRequested = ForceSyncRegistry.consumeForceSyncForCollection(remoteCollectionId);

    final String? explicitGate = local['sync_gate_reason']?.toString();
    if (explicitGate != null && explicitGate.isNotEmpty) {
      await _setCollectionGateReason(db: db, remoteCollectionId: remoteCollectionId, nextReason: explicitGate);
      debugPrint('[SYNC_GATE][remote_collection_id=$remoteCollectionId][path=$path][origin=$originKind] skipped reason=$explicitGate');
      return null;
    }

    final Map<String, dynamic> gate = _evaluateBindingEligibility(
      row: local,
      nativeCalendarsById: nativeCalendarsById,
      remoteExists: remote != null,
      hasValidAuth: hasValidAuth,
    );

    if (!(gate['eligible'] as bool)) {
      await _setCollectionGateReason(
        db: db,
        remoteCollectionId: remoteCollectionId,
        nextReason: gate['reason']?.toString(),
      );
      final String reason = gate['reason']?.toString() ?? 'unknown';
      debugPrint('[SYNC_GATE][remote_collection_id=$remoteCollectionId][path=$path][origin=$originKind] skipped reason=$reason');
      if (forceRequested) {
        debugPrint('[SYNC_FORCE][remote_collection_id=$remoteCollectionId][path=$path][origin=$originKind] force=true consumed_but_ineligible reason=$reason');
      }
      return null;
    }

    await _setCollectionGateReason(db: db, remoteCollectionId: remoteCollectionId, nextReason: null);

    final int mode = (local['sync_mode'] as int?) ?? SyncBindingMode.readOnly;
    final String? dbCtag = local['synced_ctag']?.toString();
    final String? remoteCtag = remote?['ctag']?.toString();
    final bool remoteChanged = remoteCtag != null && remoteCtag != dbCtag;
    final bool localChanged = await _isCalendarDirty(db, local['id']);
    final bool metaChanged =
        (remote?['display_name']?.toString() ?? '') != (local['display_name']?.toString() ?? '') ||
            (remote?['color']?.toString() ?? '') != (local['color']?.toString() ?? '');

    final bool isTwoWay = mode == SyncBindingMode.twoWay;
    final bool isOneWayLocalOrigin = !isTwoWay && originKind == SyncBindingOrigin.local;
    final bool isPullOnlyMode = !isTwoWay && !isOneWayLocalOrigin;

    final bool shouldSync = isTwoWay
        ? true
        : isOneWayLocalOrigin
            ? (localChanged || metaChanged)
            : isPullOnlyMode
                ? (remoteChanged || localChanged || metaChanged)
                : (remoteChanged || metaChanged);
    final bool bootstrapRequired = await _isBootstrapRequired(db, remoteCollectionId);
    final bool forceMode = forceRequested || bootstrapRequired;

    if (!shouldSync && !forceMode) {
      debugPrint('[SYNC_GATE][remote_collection_id=$remoteCollectionId][path=$path][origin=$originKind] skipped reason=no_detected_change');
      return null;
    }

    final SyncAction action = isTwoWay
        ? SyncAction.fullSyncBidi
        : isOneWayLocalOrigin
            ? SyncAction.fullSyncPush
            : SyncAction.fullSyncPull;

    return _buildContext(remote ?? {}, local, action);
  }

  Future<void> _setCollectionGateReason({
    required Database db,
    required int remoteCollectionId,
    required String? nextReason,
  }) async {
    if (remoteCollectionId <= 0) return;
    final String? normalizedReason = (nextReason == null || nextReason.isEmpty) ? null : nextReason;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'collection_states',
      {
        'remote_collection_id': remoteCollectionId,
        'sync_gate_reason': normalizedReason,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'collection_states',
      {'sync_gate_reason': normalizedReason, 'updated_at': now},
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
  }

  Map<String, dynamic> _evaluateBindingEligibility({
    required Map<String, dynamic> row,
    required Map<String, PlatformCalendar> nativeCalendarsById,
    required bool remoteExists,
    required bool hasValidAuth,
  }) {
    if (!hasValidAuth) {
      return {'eligible': false, 'reason': SyncGateReason.authInvalid};
    }

    final String remotePath = row['remote_path']?.toString() ?? '';
    if (remotePath.isEmpty) {
      return {'eligible': false, 'reason': SyncGateReason.bindingInvalid};
    }

    final int originKind = (row['origin_kind'] as int?) ?? SyncBindingOrigin.remote;
    final int bindingId = (row['binding_id'] as int?) ?? 0;
    final String localCollectionId = row['local_collection_id']?.toString() ?? '';
    if (bindingId <= 0 || localCollectionId.isEmpty) {
      if (originKind == SyncBindingOrigin.local) {
        return {'eligible': false, 'reason': SyncGateReason.reconnectRequired};
      }
      return {'eligible': false, 'reason': SyncGateReason.bindingInvalid};
    }

    final int syncMode = (row['sync_mode'] as int?) ?? SyncBindingMode.readOnly;
    final bool isSubscription = row['is_subscription'] == 1 || row['is_subscription'] == true;
    if (isSubscription && syncMode == SyncBindingMode.twoWay) {
      return {'eligible': false, 'reason': SyncGateReason.subscriptionReadonlyViolation};
    }

    final PlatformCalendar? nativeCalendar = nativeCalendarsById[localCollectionId];
    if (nativeCalendar == null) {
      return {'eligible': false, 'reason': SyncGateReason.localCalendarMissing};
    }

    final bool supportsEvents = nativeCalendar.supportsEvents ?? true;
    final bool isReadOnly = nativeCalendar.isReadOnly ?? false;
    if (!supportsEvents || (syncMode == SyncBindingMode.twoWay && isReadOnly)) {
      return {'eligible': false, 'reason': SyncGateReason.environmentBlocked};
    }

    if (!remoteExists) {
      return {'eligible': false, 'reason': SyncGateReason.remoteCollectionMissing};
    }

    return {'eligible': true, 'reason': SyncGateReason.ok};
  }

  bool _hasValidAuthContext() {
    final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
    return loginName.isNotEmpty && password.isNotEmpty;
  }

  Future<bool> _isCalendarDirty(Database db, Object? remoteCollectionId) async {
    if (remoteCollectionId == null) return false;
    final List<Map<String, dynamic>> dirtyCheck = await db.rawQuery('''
      SELECT 1 FROM sync_items
      WHERE remote_collection_id = ?
        AND sync_status = ${SyncItemStatus.pendingPush}
      LIMIT 1
    ''', [remoteCollectionId]);
    return dirtyCheck.isNotEmpty;
  }

  Future<bool> _isBootstrapRequired(Database db, int remoteCollectionId) async {
    if (remoteCollectionId <= 0) return false;
    final List<Map<String, dynamic>> rows = await db.rawQuery('''
      SELECT COUNT(1) AS count
      FROM sync_items
      WHERE remote_collection_id = ?
    ''', [remoteCollectionId]);
    final int count = (rows.firstOrNull?['count'] as int?) ?? 0;
    return count == 0;
  }

  SyncContext _buildContext(Map remote, Map local, SyncAction action) {
    return SyncContext(
      remoteCollectionId: (local['id'] as int?) ?? 0,
      localCalendarId: local['local_collection_id']?.toString() ?? '',
      remotePath: remote['remote_path'] ?? local['remote_path'] ?? '',
      accountName: local['account_name'] ?? '',
      displayName: remote['display_name'] ?? local['display_name'] ?? 'Untitled calendar',
      color: remote['color'] ?? local['color'] ?? '#AARRGGBB',
      syncMode: local['sync_mode'] ?? remote['sync_mode'] ?? 0,
      action: action,
      ctag: remote['ctag'] ?? local['synced_ctag'],
      isSubscription: remote['is_subscription'] ?? local['is_subscription'] ?? false,
      extra: {
        'binding_id': local['binding_id'] ?? 0,
        'origin_kind': local['origin_kind'] ?? SyncBindingOrigin.remote,
      },
    );
  }
}
