import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/calendar_probe_controller.dart';
import '../entity/sync_run_record.dart';
import 'sync_run_details_page.dart';

class SyncStatusDetailsPage extends StatelessWidget {
  const SyncStatusDetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<CalendarProbeController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Activity'),
        actions: [
          IconButton(onPressed: ctrl.loadRecentRuns, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Obx(() {
        final runs = ctrl.syncRuns;
        if (runs.isEmpty) {
          return const Center(child: Text('No sync activity yet.'));
        }
        return ListView.separated(
          itemCount: runs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final run = runs[index];
            final counts = _aggregateCounts(run);
            return ListTile(
              title: Text(
                '${DateFormat('MMM d, yyyy • HH:mm').format(run.startTime)} • ${_duration(run)}',
              ),
              subtitle: Text(
                '${_modeLabel(run.mode)} • ${run.bindings.length} calendar link${run.bindings.length == 1 ? '' : 's'}\n'
                'On device +${counts.localCreated}/${counts.localUpdated}/-${counts.localDeleted}  '
                'In cloud +${counts.remoteCreated}/${counts.remoteUpdated}/-${counts.remoteDeleted}',
              ),
              isThreeLine: true,
              trailing: _resultChip(run.result, run.bindings.any((b) => b.safetyGateTriggered)),
              onTap: () => Get.to(() => SyncRunDetailsPage(run: run)),
            );
          },
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: ctrl.isSyncing.value ? null : ctrl.syncNow,
        icon: const Icon(Icons.sync),
        label: const Text('Sync now'),
      ),
    );
  }
}

Widget _resultChip(SyncRunResult result, bool safetyTriggered) {
  final color = switch (result) {
    SyncRunResult.success => Colors.green,
    SyncRunResult.partial => Colors.orange,
    SyncRunResult.abortedBySafety => Colors.deepOrange,
    SyncRunResult.failed => Colors.red,
  };
  final label = switch (result) {
    SyncRunResult.success => 'Up to date',
    SyncRunResult.partial => 'Partly synced',
    SyncRunResult.abortedBySafety => 'Stopped for safety',
    SyncRunResult.failed => 'Sync failed',
  };
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Chip(label: Text(label), backgroundColor: color.withOpacity(0.15)),
      if (safetyTriggered) const Text('Safety check', style: TextStyle(fontSize: 11, color: Colors.deepOrange)),
    ],
  );
}

String _duration(SyncRunRecord run) {
  final ms = run.durationMs ?? 0;
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

class _SyncChangeSummary {
  const _SyncChangeSummary({
    required this.localCreated,
    required this.localUpdated,
    required this.localDeleted,
    required this.remoteCreated,
    required this.remoteUpdated,
    required this.remoteDeleted,
  });

  final int localCreated;
  final int localUpdated;
  final int localDeleted;
  final int remoteCreated;
  final int remoteUpdated;
  final int remoteDeleted;
}

_SyncChangeSummary _aggregateCounts(SyncRunRecord run) {
  int localCreated = 0, localUpdated = 0, localDeleted = 0;
  int remoteCreated = 0, remoteUpdated = 0, remoteDeleted = 0;
  for (final b in run.bindings) {
    localCreated += b.localCounts.created;
    localUpdated += b.localCounts.updated;
    localDeleted += b.localCounts.deleted;
    remoteCreated += b.remoteCounts.created;
    remoteUpdated += b.remoteCounts.updated;
    remoteDeleted += b.remoteCounts.deleted;
  }

  return _SyncChangeSummary(
    localCreated: localCreated,
    localUpdated: localUpdated,
    localDeleted: localDeleted,
    remoteCreated: remoteCreated,
    remoteUpdated: remoteUpdated,
    remoteDeleted: remoteDeleted,
  );
}

String _modeLabel(SyncRunMode mode) {
  return switch (mode) {
    SyncRunMode.pull => 'Import only',
    SyncRunMode.push => 'Export only',
    SyncRunMode.twoWay => 'Two-way sync',
  };
}
