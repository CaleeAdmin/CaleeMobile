import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';

import 'SyncStrategy.dart';

class FullSyncPullStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (ctx.localCalendarId.isEmpty || ctx.remoteCollectionId <= 0) {
      return;
    }

    try {
      final bool bootstrap = ctx.extra['bootstrap_required'] == true;
      await runUnifiedSync(ctx, summary, mode: UnifiedSyncMode.pull, bootstrap: bootstrap);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Pull sync exception: $e');
    }
  }
}
