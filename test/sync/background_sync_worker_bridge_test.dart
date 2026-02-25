import 'dart:async';
import 'dart:io';

import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/background_sync_worker_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contract mismatch -> failure/unknown gate', () async {
    final bridge = BackgroundSyncWorkerBridge(loginNameReader: () => 'u1');
    final out = await bridge.runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: 999));
    expect(out.outcome, BackgroundRunOutcome.failure);
    expect(out.reason, 'contract_mismatch');
    expect(out.gateReason, BackgroundGateReason.unknown);
  });

  test('missing account -> failure/authInvalid gate', () async {
    final bridge = BackgroundSyncWorkerBridge(loginNameReader: () => '');
    final out = await bridge.runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(out.outcome, BackgroundRunOutcome.failure);
    expect(out.gateReason, BackgroundGateReason.authInvalid);
  });

  test('summary and exception classification', () async {
    Future<SyncSummary> successRun(_) async => SyncSummary();
    final success = await BackgroundSyncWorkerBridge(executeSync: successRun, loginNameReader: () => 'u1')
        .runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(success.outcome, BackgroundRunOutcome.success);

    final gatedSummary = SyncSummary()..failed = 1..errorLog.add('binding_invalid');
    final gated = await BackgroundSyncWorkerBridge(executeSync: (_) async => gatedSummary, loginNameReader: () => 'u1')
        .runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(gated.outcome, BackgroundRunOutcome.gated);
    expect(gated.gateReason, BackgroundGateReason.bindingInvalid);

    final retrySummary = SyncSummary()..failed = 1..errorLog.add('temporary timeout');
    final retry = await BackgroundSyncWorkerBridge(executeSync: (_) async => retrySummary, loginNameReader: () => 'u1')
        .runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(retry.outcome, BackgroundRunOutcome.retry);

    final failedSummary = SyncSummary()..failed = 1..errorLog.add('bad request');
    final failed = await BackgroundSyncWorkerBridge(executeSync: (_) async => failedSummary, loginNameReader: () => 'u1')
        .runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(failed.outcome, BackgroundRunOutcome.failure);

    final socket = await BackgroundSyncWorkerBridge(
      executeSync: (_) async => throw const SocketException('offline'),
      loginNameReader: () => 'u1',
    ).runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(socket.outcome, BackgroundRunOutcome.retry);

    final timeout = await BackgroundSyncWorkerBridge(
      executeSync: (_) async => throw TimeoutException('late'),
      loginNameReader: () => 'u1',
    ).runBackgroundSync(BackgroundRunRequest(trigger: 'manual', contractVersion: kBackgroundSyncContractVersion));
    expect(timeout.outcome, BackgroundRunOutcome.retry);
  });
}
