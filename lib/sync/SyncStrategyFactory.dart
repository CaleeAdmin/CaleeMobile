import 'package:caleesync/sync/DeleteLocalStrategy.dart';
import 'package:caleesync/sync/DeleteRemoteStrategy.dart';
import 'package:caleesync/sync/FullSyncPullStrategy.dart';
import 'package:caleesync/sync/FullSyncPushStrategy.dart';

import 'SyncEnum.dart';
import 'CreateLocalStrategy.dart';
import 'CreateRemoteStrategy.dart';
import 'SyncStrategy.dart';

class SyncStrategyFactory {
  static final Map<SyncAction, SyncStrategy> _strategies = {
    SyncAction.createRemote: CreateRemoteStrategy(),
    SyncAction.createLocal: CreateLocalStrategy(),
    SyncAction.deleteLocal: Deletelocalstrategy(),
    SyncAction.deleteRemote: DeleteRemoteStrategy(),
    SyncAction.fullSyncPull: FullSyncPullStrategy(),
    SyncAction.fullSyncPush: FullSyncPushStrategy(),
    SyncAction.deleteDatabaseOnly: DeleteRemoteStrategy(),
    // SyncAction.fullSync: FullSyncStrategy(), // 以后添加双向同步
  };

  static SyncStrategy? getStrategy(SyncAction action) => _strategies[action];
}