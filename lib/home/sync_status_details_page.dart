import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/calendar_probe_controller.dart';
import '../entity/sync_run_record.dart';
import 'sync_settings_page.dart';
import 'sync_run_details_page.dart';

class SyncStatusDetailsPage extends StatelessWidget {
  const SyncStatusDetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<CalendarProbeController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(Platform.isIOS ? 'Connection Activity' : 'Sync Activity'),
        actions: [
          IconButton(onPressed: ctrl.loadRecentRuns, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Obx(() {
        final runs = ctrl.syncRuns;
        if (runs.isEmpty) {
          return Center(
            child: Text(
              Platform.isIOS
                  ? 'No connection activity yet.'
                  : 'No sync activity yet.',
            ),
          );
        }
        return ListView.separated(
          itemCount: runs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final run = runs[index];
            final counts = _aggregateCounts(run);
            return ListTile(
              title: Text(
                '${_formatTimestamp(run.startTime)} • ${_duration(run)}',
              ),
              subtitle: Text(
                '${_triggerLabel(run.trigger)} • ${run.bindings.length} ${run.bindings.length == 1 ? 'source' : 'sources'}\n'
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
        onPressed: ctrl.isSyncing.value
            ? null
            : () {
                if (Platform.isIOS) {
                  Get.to(() => const SyncSettingsPage());
                  return;
                }
                ctrl.syncNow();
              },
        icon: Icon(Platform.isIOS ? Icons.settings : Icons.sync),
        label: Text(Platform.isIOS ? 'Open Connections' : 'Sync now'),
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
    SyncRunResult.skippedNoEnabledSources => Colors.blueGrey,
    SyncRunResult.skippedNoChanges => Colors.blueGrey,
  };
  final label = switch (result) {
    SyncRunResult.success => 'Succeeded',
    SyncRunResult.partial => 'Partially Synced',
    SyncRunResult.abortedBySafety => 'Stopped for Safety',
    SyncRunResult.failed => 'Failed',
    SyncRunResult.skippedNoEnabledSources => 'Skipped (No Enabled Sources)',
    SyncRunResult.skippedNoChanges => 'Skipped (No Changes)',
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

String _formatTimestamp(DateTime time) {
  final local = time.toLocal();
  final abs = DateFormat('MMM d, yyyy • HH:mm').format(local);
  final diff = DateTime.now().difference(local);
  final rel = diff.inMinutes < 1
      ? 'just now'
      : diff.inHours < 1
          ? '${diff.inMinutes}m ago'
          : diff.inDays < 1
              ? '${diff.inHours}h ago'
              : '${diff.inDays}d ago';
  return '$abs ($rel)';
}

String _triggerLabel(SyncRunTrigger trigger) {
  return switch (trigger) {
    SyncRunTrigger.manual => 'manual',
    SyncRunTrigger.autoForeground => 'auto (foreground)',
    SyncRunTrigger.periodic => 'background',
    SyncRunTrigger.force => 'force',
  };
}
