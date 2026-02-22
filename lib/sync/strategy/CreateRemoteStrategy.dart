import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';

import 'SyncStrategy.dart';

class CreateRemoteStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null ||
        loginName?.isEmpty == true ||
        password == null ||
        password?.isEmpty == true) {
      return;
    }
    final String targetPathId = "calee_${DateTime.now().millisecondsSinceEpoch}";

    // 调用创建接口
    final resultPath = await nc.createRemoteCalendar(
      userId: loginName!,
      calendarName: ctx.displayName,
      calendarId: targetPathId,
      color: ctx.color, // 记得带上我们之前讨论的颜色
    );
    if (resultPath != null) {
      final db = await dbHelper.database;
      await db.rawUpdate('''
        UPDATE remote_collections
        SET remote_path = ?
        WHERE id IN (
          SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?
        )
      ''', [resultPath, ctx.localCalendarId]);

      final SyncContext bootstrapCtx = ctx.copyWith(
        remotePath: resultPath,
        action: SyncAction.fullSyncPush,
      );
      await runUnifiedSync(
        bootstrapCtx,
        summary,
        mode: UnifiedSyncMode.push,
        bootstrap: true,
      );
    }
  }
}
