import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:flutter/cupertino.dart';

import '../entity/SyncSummary.dart';
import '../services/calee_auth_service.dart';
import '../services/calee_server_service.dart';
import 'force_sync_registry.dart';
import 'sync_item_executor.dart';
import 'sync_item_planner.dart';

class SyncEngine {
  SyncEngine({
    SyncRepository? repo,
    CaleeServerService? serverService,
    CaleeAuthService? authService,
    SyncItemPlanner? planner,
    SyncItemExecutor? executor,
  })  : _repo = repo ?? SyncRepository(),
        _serverService = serverService ?? CaleeServerService(),
        _authService = authService ?? CaleeAuthService(serverBaseUrl: AppConstant.caleeServer),
        _planner = planner ?? SyncItemPlanner(),
        _executor = executor ?? SyncItemExecutor();

  final SyncRepository _repo;
  final CaleeServerService _serverService;
  final CaleeAuthService _authService;
  final SyncItemPlanner _planner;
  final SyncItemExecutor _executor;

  static void requestForceSyncForCollection(int remoteCollectionId) {
    ForceSyncRegistry.requestForceSyncForCollection(remoteCollectionId);
  }

  Future<SyncSummary> executeFullSync({Function(SyncSummary)? onProgress}) async {
    final summary = SyncSummary();
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
    if (loginName == null) return summary;

    await _repo.scanLocalCalendars(loginName);
    await _repo.refreshAllLocalEvents(loginName);

    final List<Map<String, dynamic>> remoteCalendars = await _serverService.scanRemoteCalendars(
      serverUrl: _authService.normalizedUrl,
      userId: loginName,
    );

    final syncItems = await _planner.generateSyncItems(loginName, remoteCalendars);
    debugPrint('====generateSyncItems===$syncItems');

    summary.reset(syncItems.length);

    for (final syncItem in syncItems) {
      summary.processing++;
      onProgress?.call(summary);

      await _executor.execute(syncItem, summary);

      onProgress?.call(summary);
    }

    return summary;
  }
}
