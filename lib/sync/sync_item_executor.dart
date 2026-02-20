import 'package:flutter/cupertino.dart';

import '../entity/SyncContext.dart';
import '../entity/SyncSummary.dart';
import 'factory/SyncStrategyFactory.dart';

class SyncItemExecutor {
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    final strategy = SyncStrategyFactory.getSyncStrategy(ctx.action);
    if (strategy == null) {
      debugPrint("未定义的同步策略: ${ctx.action}");
      return;
    }

    try {
      await strategy.execute(ctx, summary);
    } catch (e) {
      summary.failed++;
      summary.errorLog.add("${ctx.displayName} 异常: $e");
    }
  }
}
