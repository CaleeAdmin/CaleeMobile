import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../data/database_helper.dart';
import '../entity/SyncContext.dart';
import '../services/calee_server_service.dart';
import 'SyncEnum.dart';
import 'force_sync_registry.dart';

class SyncItemPlanner {
  SyncItemPlanner({
    DatabaseHelper? dbHelper,
    NativeCalendarApi? nativeApi,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _native = nativeApi ?? NativeCalendarApi();

  final DatabaseHelper _dbHelper;
  final NativeCalendarApi _native;

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
        lb.binding_origin
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
    final Set<String> nativeIds = nativeCalendars
        .whereType<PlatformCalendar>()
        .map((calendar) => calendar.id ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final List<SyncContext> contexts = [];
    for (final local in collectionRows) {
      final SyncContext? context = await _buildSyncItemContext(
        db: db,
        local: local,
        remoteMap: remoteMap,
        nativeIds: nativeIds,
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
    required Set<String> nativeIds,
  }) async {
    final String path = CaleeServerService.normalizeRemotePath(local['remote_path']?.toString() ?? '');
    final Map<String, dynamic>? remote = remoteMap[path];
    final int remoteCollectionId = (local['id'] as int?) ?? 0;
    final int bindingId = (local['binding_id'] as int?) ?? 0;
    final int bindingOrigin = (local['binding_origin'] as int?) ?? SyncBindingOrigin.remote;

    final bool forceRequested = ForceSyncRegistry.consumeForceSyncForCollection(remoteCollectionId);

    final Map<String, dynamic> gate = _evaluateBindingEligibility(
      row: local,
      nativeCalendarIds: nativeIds,
      remoteExists: remote != null,
    );

    if (!(gate['eligible'] as bool)) {
      await _handleIneligibleBinding(
        db: db,
        local: local,
        path: path,
        gate: gate,
        bindingId: bindingId,
        bindingOrigin: bindingOrigin,
        forceRequested: forceRequested,
      );
      return null;
    }

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

    final bool shouldSync = isTwoWay
        ? (remoteChanged || localChanged || metaChanged)
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

  Future<void> _handleIneligibleBinding({
    required Database db,
    required Map<String, dynamic> local,
    required String path,
    required Map<String, dynamic> gate,
    required int bindingId,
    required int bindingOrigin,
    required bool forceRequested,
  }) async {
    final String reason = gate['reason']?.toString() ?? 'unknown';
    final String uiHint = gate['ui_hint']?.toString() ?? '';
    final int remoteCollectionId = (local['id'] as int?) ?? 0;

    debugPrint('[SYNC_GATE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] skipped reason=$reason hint=$uiHint');
    if (forceRequested) {
      debugPrint('[SYNC_FORCE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] force=true consumed_but_ineligible reason=$reason');
    }

    if (reason == 'local_calendar_missing' && remoteCollectionId > 0) {
      await db.update(
        'remote_collections',
        {'is_enabled': 0},
        where: 'id = ?',
        whereArgs: [remoteCollectionId],
      );
      debugPrint('[SYNC_GATE][binding_id=$bindingId][origin=$bindingOrigin] disabled_due_to_missing_local_calendar');
    }
  }

  Map<String, dynamic> _evaluateBindingEligibility({
    required Map<String, dynamic> row,
    required Set<String> nativeCalendarIds,
    required bool remoteExists,
  }) {
    final int isEnabled = (row['is_enabled'] as int?) ?? 0;
    if (isEnabled != 1) {
      return {'eligible': false, 'reason': 'remote_collection_disabled'};
    }

    final String remotePath = row['remote_path']?.toString() ?? '';
    if (remotePath.isEmpty) {
      return {'eligible': false, 'reason': 'missing_remote_path'};
    }

    final int bindingId = (row['binding_id'] as int?) ?? 0;
    if (bindingId <= 0) {
      return {'eligible': false, 'reason': 'missing_binding_id', 'ui_hint': 'Bind to a local calendar to sync'};
    }

    final String localCollectionId = row['local_collection_id']?.toString() ?? '';
    if (localCollectionId.isEmpty) {
      return {'eligible': false, 'reason': 'missing_local_collection_id', 'ui_hint': 'Bind to a local calendar to sync'};
    }

    if (!nativeCalendarIds.contains(localCollectionId)) {
      return {'eligible': false, 'reason': 'local_calendar_missing', 'ui_hint': 'Local calendar not found'};
    }

    if (!remoteExists) {
      return {'eligible': false, 'reason': 'remote_collection_missing', 'ui_hint': 'Remote path mismatch'};
    }

    return {'eligible': true, 'reason': 'ok'};
  }

  Future<bool> _isCalendarDirty(Database db, Object? remoteCollectionId) async {
    if (remoteCollectionId == null) return false;
    final List<Map<String, dynamic>> dirtyCheck = await db.rawQuery('''
      SELECT 1 FROM sync_items
      WHERE remote_collection_id = ?
        AND sync_status IN (${SyncItemStatus.pendingPush}, ${SyncItemStatus.pendingDelete})
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
      displayName: remote['display_name'] ?? local['display_name'] ?? '未命名日历',
      color: remote['color'] ?? local['color'] ?? '#AARRGGBB',
      syncMode: local['sync_mode'] ?? remote['sync_mode'] ?? 0,
      action: action,
      ctag: remote['ctag'] ?? local['synced_ctag'],
      isSubscription: remote['is_subscription'] ?? local['is_subscription'] ?? false,
      extra: {
        'binding_id': local['binding_id'] ?? 0,
        'binding_origin': local['binding_origin'] ?? 0,
      },
    );
  }
}
