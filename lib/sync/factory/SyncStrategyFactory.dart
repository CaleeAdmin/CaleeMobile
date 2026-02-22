import 'package:caleesync/sync/strategy/DeleteRemoteStrategy.dart';

import '../strategy/DeleteDatabaseOnlyStrategy.dart';
import '../strategy/DeleteLocalStrategy.dart';
import '../strategy/FullSyncBidiStrategy.dart';
import '../SyncEnum.dart';
import '../strategy/FullSyncPullStrategy.dart';
import '../strategy/FullSyncPushStrategy.dart';
import '../strategy/SyncStrategy.dart';

class SyncStrategyFactory {
  static final Map<ProvisioningAction, SyncStrategy> _uiProvisioningStrategies = {
    ProvisioningAction.uiDeleteLocalCalendar: Deletelocalstrategy(),
    ProvisioningAction.uiDeleteRemoteCalendar: DeleteRemoteStrategy(),
    ProvisioningAction.uiDeleteDatabaseOnly: DeleteDatabaseOnlyStrategy(),
  };

  static final Map<SyncAction, SyncStrategy> _syncSafeStrategies = {
    SyncAction.fullSyncPull: FullSyncPullStrategy(),
    SyncAction.fullSyncPush: FullSyncPushStrategy(),
    SyncAction.fullSyncBidi: FullSyncBidiStrategy(),
  };

  static SyncStrategy? getSyncStrategy(SyncAction action) =>
      _syncSafeStrategies[action];

  static SyncStrategy? getProvisioningStrategy(ProvisioningAction action) =>
      _uiProvisioningStrategies[action];
}
