import 'package:flutter/material.dart';

import '../entity/sync_run_record.dart';

class SyncRunDetailsPage extends StatelessWidget {
  const SyncRunDetailsPage({super.key, required this.run});

  final SyncRunRecord run;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Sync details • ${run.runId.substring(0, 8)}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Sync type: ${_modeLabel(run.mode)}'),
          Text('Trigger: ${run.trigger.name}'),
          Text('Overall result: ${_runResultLabel(run.result)}'),
          Text('Time spent: ${((run.durationMs ?? 0) / 1000).toStringAsFixed(1)}s'),
          const SizedBox(height: 12),
          ...run.bindings.map((b) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Calendar link: ${b.bindingIdentifier}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Account: ${b.accountIdentifier}'),
                    Text('Status: ${_bindingResultLabel(b.resultStatus)}'),
                    Text('Trusted source: ${_trustLabel(b.snapshotTrustStatus)}'),
                    Text('Safety check triggered: ${b.safetyGateTriggered ? 'Yes' : 'No'}'),
                    Text('On device: +${b.localCounts.created} / ${b.localCounts.updated} / -${b.localCounts.deleted}'),
                    Text('In cloud: +${b.remoteCounts.created} / ${b.remoteCounts.updated} / -${b.remoteCounts.deleted}'),
                    if (b.errorCode != null) ...[
                      const SizedBox(height: 8),
                      const Text('What needs attention', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      Text('Issue: ${b.errorMessage ?? 'Something went wrong while syncing this calendar.'}'),
                      Text('What to do: ${_recommendation(b.errorCode!)}'),
                      ExpansionTile(
                        title: const Text('More details (for support)'),
                        tilePadding: EdgeInsets.zero,
                        children: [Align(alignment: Alignment.centerLeft, child: Text(b.technicalDetail ?? '-'))],
                      )
                    ]
                  ]),
                ),
              ))
        ],
      ),
    );
  }
}

String _recommendation(SyncErrorCode code) {
  switch (code) {
    case SyncErrorCode.networkUnavailable:
      return 'Check your internet connection, then try again.';
    case SyncErrorCode.authExpired:
      return 'Reconnect your account and run sync again.';
    case SyncErrorCode.remoteCalendarMissing:
      return 'Make sure the destination calendar still exists.';
    case SyncErrorCode.permissionDenied:
      return 'Review permissions, allow access, and retry.';
    case SyncErrorCode.parseOrServerResponse:
      return 'Try again in a few minutes.';
    case SyncErrorCode.localProviderFailure:
      return 'Check that your device calendar is available and try again.';
    case SyncErrorCode.dbOrMappingConflict:
      return 'Run sync again to rebuild the calendar link.';
    case SyncErrorCode.safetyStop:
      return 'Review large deletion changes before running sync again.';
    case SyncErrorCode.unknown:
      return 'Try syncing again. If it keeps failing, contact support.';
  }
}

String _modeLabel(SyncRunMode mode) {
  return switch (mode) {
    SyncRunMode.pull => 'Import only',
    SyncRunMode.push => 'Export only',
    SyncRunMode.twoWay => 'Two-way sync',
  };
}

String _runResultLabel(SyncRunResult result) {
  return switch (result) {
    SyncRunResult.success => 'Succeeded',
    SyncRunResult.partial => 'Partially Synced',
    SyncRunResult.failed => 'Failed',
    SyncRunResult.abortedBySafety => 'Stopped for Safety',
    SyncRunResult.skippedNoEnabledSources => 'Skipped (No Enabled Sources)',
    SyncRunResult.skippedNoChanges => 'Skipped (No Changes)',
  };
}

String _bindingResultLabel(SyncBindingResultStatus result) {
  return switch (result) {
    SyncBindingResultStatus.success => 'Synced',
    SyncBindingResultStatus.partial => 'Partly synced',
    SyncBindingResultStatus.failed => 'Failed',
    SyncBindingResultStatus.abortedBySafety => 'Stopped for safety',
  };
}

String _trustLabel(SnapshotTrustStatus status) {
  return switch (status) {
    SnapshotTrustStatus.remote => 'Cloud calendar',
    SnapshotTrustStatus.local => 'Device calendar',
    SnapshotTrustStatus.unknown => 'Not sure',
  };
}
