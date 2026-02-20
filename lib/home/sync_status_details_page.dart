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
        title: const Text('Sync History'),
        actions: [
          IconButton(onPressed: ctrl.loadRecentRuns, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Obx(() {
        final runs = ctrl.syncRuns;
        if (runs.isEmpty) {
          return const Center(child: Text('No sync runs yet.'));
        }
        return ListView.separated(
          itemCount: runs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final run = runs[index];
            final counts = _aggregateCounts(run);
            return ListTile(
              title: Text('${DateFormat('yyyy-MM-dd HH:mm').format(run.startTime)}  ·  ${_duration(run)}'),
              subtitle: Text('${run.mode.name.toUpperCase()} · ${run.bindings.length} bindings\n'
                  'L +${counts.$1}/${counts.$2}/-${counts.$3}  R +${counts.$4}/${counts.$5}/-${counts.$6}'),
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
        label: const Text('Sync Now'),
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
    SyncRunResult.success => 'Success',
    SyncRunResult.partial => 'Partial',
    SyncRunResult.abortedBySafety => 'Aborted',
    SyncRunResult.failed => 'Failed',
  };
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Chip(label: Text(label), backgroundColor: color.withOpacity(0.15)),
      if (safetyTriggered) const Text('🛑 Safety', style: TextStyle(fontSize: 11, color: Colors.deepOrange)),
    ],
  );
}

String _duration(SyncRunRecord run) {
  final ms = run.durationMs ?? 0;
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

(int, int, int, int, int, int) _aggregateCounts(SyncRunRecord run) {
  int lc = 0, lu = 0, ld = 0, rc = 0, ru = 0, rd = 0;
  for (final b in run.bindings) {
    lc += b.localCounts.created;
    lu += b.localCounts.updated;
    ld += b.localCounts.deleted;
    rc += b.remoteCounts.created;
    ru += b.remoteCounts.updated;
    rd += b.remoteCounts.deleted;
  }
  return (lc, lu, ld, rc, ru, rd);
}
