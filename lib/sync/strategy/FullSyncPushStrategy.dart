import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';

import 'SyncStrategy.dart';

class FullSyncPushStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null || loginName!.isEmpty || password == null || password!.isEmpty) {
      return;
    }

    try {
      await runUnifiedSync(ctx, summary, mode: UnifiedSyncMode.push);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Push sync exception: $e');
    }
  }
}
