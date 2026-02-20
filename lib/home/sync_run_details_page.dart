import 'package:flutter/material.dart';

import '../entity/sync_run_record.dart';

class SyncRunDetailsPage extends StatelessWidget {
  const SyncRunDetailsPage({super.key, required this.run});

  final SyncRunRecord run;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Run ${run.runId.substring(0, 8)}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Mode: ${run.mode.name}'),
          Text('Result: ${run.result.name}'),
          Text('Duration: ${(run.durationMs ?? 0) / 1000}s'),
          const SizedBox(height: 12),
          ...run.bindings.map((b) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(b.bindingIdentifier, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Account: ${b.accountIdentifier}'),
                    Text('Snapshot trust: ${b.snapshotTrustStatus.name}'),
                    Text('Safety gate: ${b.safetyGateTriggered ? 'YES' : 'No'}'),
                    Text('Local: +${b.localCounts.created} ~${b.localCounts.updated} -${b.localCounts.deleted}'),
                    Text('Remote: +${b.remoteCounts.created} ~${b.remoteCounts.updated} -${b.remoteCounts.deleted}'),
                    if (b.errorCode != null) ...[
                      const SizedBox(height: 8),
                      Text('Error code: ${b.errorCode!.name}', style: const TextStyle(color: Colors.red)),
                      Text('Message: ${b.errorMessage ?? 'Unknown error'}'),
                      Text('Recommended action: ${_recommendation(b.errorCode!)}'),
                      ExpansionTile(
                        title: const Text('Technical detail'),
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
      return 'Check connectivity and retry.';
    case SyncErrorCode.authExpired:
      return 'Re-authenticate your account.';
    case SyncErrorCode.remoteCalendarMissing:
      return 'Verify remote calendar still exists.';
    case SyncErrorCode.permissionDenied:
      return 'Grant permissions and retry.';
    case SyncErrorCode.parseOrServerResponse:
      return 'Retry later; server response may be invalid.';
    case SyncErrorCode.localProviderFailure:
      return 'Check local calendar provider availability.';
    case SyncErrorCode.dbOrMappingConflict:
      return 'Run sync again to repair mapping.';
    case SyncErrorCode.safetyStop:
      return 'Review potential mass deletion and retry intentionally.';
    case SyncErrorCode.unknown:
      return 'Retry and inspect diagnostics.';
  }
}
