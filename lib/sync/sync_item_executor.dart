import 'package:flutter/cupertino.dart';

import '../entity/SyncContext.dart';
import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import 'factory/SyncStrategyFactory.dart';
import 'sync_run_recorder.dart';

class SyncItemExecutor {
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    final strategy = SyncStrategyFactory.getSyncStrategy(ctx.action);
    if (strategy == null) {
      debugPrint("未定义的同步策略: ${ctx.action}");
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.failed,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: false,
        errorCode: SyncErrorCode.unknown,
        errorMessage: 'Undefined sync strategy',
      );
      return;
    }

    try {
      await strategy.execute(ctx, summary);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add("${ctx.displayName} 异常: $e");
      final code = mapSyncErrorCode(e);
      summary.telemetry?.onError(ctx: ctx, code: code, message: 'Sync failed', technicalDetail: e.toString());
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.failed,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: false,
        errorCode: code,
        errorMessage: 'Sync failed',
        technicalDetail: e.toString(),
      );
    }
  }
}
