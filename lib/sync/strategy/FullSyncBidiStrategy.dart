import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';

import 'SyncStrategy.dart';

class FullSyncBidiStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null || loginName!.isEmpty) {
      return;
    }

    try {
      final bool bootstrap = ctx.extra['bootstrap_required'] == true;
      await runUnifiedSync(ctx, summary, mode: UnifiedSyncMode.bidi, bootstrap: bootstrap);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Two-way sync exception: $e');
    }
  }
}
