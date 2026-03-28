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
      final bool bootstrap = ctx.extra['bootstrap_required'] == true;
      await runUnifiedSync(ctx, summary, mode: UnifiedSyncMode.push, bootstrap: bootstrap);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Push sync exception: $e');
    }
  }
}
