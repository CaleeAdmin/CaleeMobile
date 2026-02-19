import 'package:caleesync/sync/strategy/DeleteRemoteStrategy.dart';

import '../strategy/DeleteLocalStrategy.dart';
import '../strategy/FullSyncBidiStrategy.dart';
import '../SyncEnum.dart';
import '../strategy/CreateRemoteStrategy.dart';
import '../strategy/FullSyncPullStrategy.dart';
import '../strategy/FullSyncPushStrategy.dart';
import '../strategy/SyncStrategy.dart';

class SyncStrategyFactory {
  static final Map<SyncAction, SyncStrategy> _strategies = {
    SyncAction.createRemote: CreateRemoteStrategy(),
    SyncAction.deleteLocal: Deletelocalstrategy(),
    SyncAction.deleteRemote: DeleteRemoteStrategy(),
    SyncAction.fullSyncPull: FullSyncPullStrategy(),
    SyncAction.fullSyncPush: FullSyncPushStrategy(),
    SyncAction.deleteDatabaseOnly: DeleteRemoteStrategy(),
    SyncAction.fullSyncBidi: FullSyncBidiStrategy(),
  };

  static SyncStrategy? getStrategy(SyncAction action) => _strategies[action];
}