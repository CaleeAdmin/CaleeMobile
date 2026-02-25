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
    bool Function(String userId)? authValidator,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _native = nativeApi ?? NativeCalendarApi(),
        _authValidator = authValidator;

  final DatabaseHelper _dbHelper;
  final NativeCalendarApi _native;
  final bool Function(String userId)? _authValidator;

  Future<List<SyncContext>> generateSyncItems(
    String userId,
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
        rc.is_enabled,
        rc.is_subscription,
        lb.id AS binding_id,
        lb.local_collection_id,
        lb.binding_origin,
        lb.sync_gate_reason
      FROM remote_collections rc
      LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE rc.account_name = ?
        AND rc.collection_type = 'calendar'
    ''', [userId]);

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

    final bool hasValidAuth = _hasValidAuthContext(userId);

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
    final int isEnabled = (local['is_enabled'] as int?) ?? 0;
    final int bindingId = (local['binding_id'] as int?) ?? 0;
    final int bindingOrigin = (local['binding_origin'] as int?) ?? SyncBindingOrigin.remote;

    // Disabled collections are user-intent OFF and should not be gated or
    // considered by planner reconciliation/execution.
    if (isEnabled != 1) {
      return null;
    }

    final bool forceRequested = ForceSyncRegistry.consumeForceSyncForCollection(remoteCollectionId);

    final Map<String, dynamic> gate = _evaluateBindingEligibility(
      row: local,
      nativeCalendarsById: nativeCalendarsById,
      remoteExists: remote != null,
      hasValidAuth: hasValidAuth,
    );

    if (!(gate['eligible'] as bool)) {
      await _setSyncGateReason(
        db: db,
        bindingId: bindingId,
        nextReason: gate['reason']?.toString(),
      );
      final String reason = gate['reason']?.toString() ?? 'unknown';
      debugPrint('[SYNC_GATE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] skipped reason=$reason');
      if (forceRequested) {
        debugPrint('[SYNC_FORCE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] force=true consumed_but_ineligible reason=$reason');
      }
      return null;
    }

    await _setSyncGateReason(
      db: db,
      bindingId: bindingId,
      nextReason: null,
    );

    final int mode = (local['sync_mode'] as int?) ?? SyncBindingMode.readOnly;
    final String? dbCtag = local['synced_ctag']?.toString();
    final String? remoteCtag = remote?['ctag']?.toString();
    final bool remoteChanged = remoteCtag != null && remoteCtag != dbCtag;
    final bool localChanged = await _isCalendarDirty(db, local['id']);
    final bool metaChanged =
        (remote?['display_name']?.toString() ?? '') != (local['display_name']?.toString() ?? '') ||
            (remote?['color']?.toString() ?? '') != (local['color']?.toString() ?? '');

    final bool isTwoWay = mode == SyncBindingMode.twoWay;
    final bool isOneWayRemoteOrigin = !isTwoWay && bindingOrigin == SyncBindingOrigin.remote;
    final bool isOneWayLocalOrigin = !isTwoWay && bindingOrigin == SyncBindingOrigin.local;

    // Two-way sync must always enter item-level planning. Collection-level
    // gates (ctag / pending flags) are only heuristics and can miss updates
    // (for example, when local change markers are absent).
    final bool shouldSync = isTwoWay
        ? true
        : isOneWayRemoteOrigin
            ? (remoteChanged || metaChanged)
            : (localChanged || metaChanged);
    final bool bootstrapRequired = await _isBootstrapRequired(db, remoteCollectionId);
    final bool forceMode = forceRequested || bootstrapRequired;

    if (!shouldSync && !forceMode) {
      debugPrint('[SYNC_GATE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] skipped reason=no_detected_change');
      return null;
    }

    if (forceMode) {
      final String localCollectionId = local['local_collection_id']?.toString() ?? '';
      final String modeName = isTwoWay
          ? 'bidi'
          : isOneWayLocalOrigin
              ? 'push'
              : 'pull';
      debugPrint('[SYNC_FORCE][binding_id=$bindingId][path=$path][local=$localCollectionId][origin=$bindingOrigin][mode=$modeName] force=true requested=$forceRequested bootstrap=$bootstrapRequired');
    }

    final SyncAction action = isTwoWay
        ? SyncAction.fullSyncBidi
        : isOneWayLocalOrigin
            ? SyncAction.fullSyncPush
            : SyncAction.fullSyncPull;

    final String modeName = action == SyncAction.fullSyncBidi
        ? 'bidi'
        : action == SyncAction.fullSyncPush
            ? 'push'
            : 'pull';
    debugPrint('[SYNC_PLAN][binding_id=$bindingId][path=$path][origin=$bindingOrigin][mode=$modeName] changed(remote=$remoteChanged local=$localChanged meta=$metaChanged)');

    return _buildContext(remote ?? {}, local, action);
  }


  Future<void> _setSyncGateReason({
    required Database db,
    required int bindingId,
    required String? nextReason,
  }) async {
    if (bindingId <= 0) return;

    final String? normalizedReason = (nextReason == null || nextReason.isEmpty) ? null : nextReason;
    await db.update(
      'local_bindings',
      {'sync_gate_reason': normalizedReason},
      where: 'id = ?',
      whereArgs: [bindingId],
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

    final int bindingId = (row['binding_id'] as int?) ?? 0;
    if (bindingId <= 0) {
      return {'eligible': false, 'reason': SyncGateReason.bindingInvalid};
    }

    final String localCollectionId = row['local_collection_id']?.toString() ?? '';
    if (localCollectionId.isEmpty) {
      return {'eligible': false, 'reason': SyncGateReason.bindingInvalid};
    }

    final int bindingOrigin = (row['binding_origin'] as int?) ?? SyncBindingOrigin.remote;
    final bool isValidBindingOrigin =
        bindingOrigin == SyncBindingOrigin.local || bindingOrigin == SyncBindingOrigin.remote;
    if (!isValidBindingOrigin) {
      return {'eligible': false, 'reason': SyncGateReason.repairRequired};
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

  bool _hasValidAuthContext(String userId) {
    final custom = _authValidator;
    if (custom != null) return custom(userId);
    final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
    if (loginName.isEmpty || password.isEmpty) {
      return false;
    }
    return loginName == userId;
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
    final dynamic subscriptionRaw = remote.containsKey('is_subscription')
        ? remote['is_subscription']
        : local['is_subscription'];
    final bool isSubscription = subscriptionRaw == true || subscriptionRaw == 1 || subscriptionRaw?.toString() == '1';

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
      isSubscription: isSubscription,
      extra: {
        'binding_id': local['binding_id'] ?? 0,
        'binding_origin': local['binding_origin'] ?? 0,
      },
    );
  }
}
