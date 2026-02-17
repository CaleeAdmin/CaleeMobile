import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/calendar_probe_controller.dart';

class SyncStatusDetailsPage extends StatelessWidget {
  const SyncStatusDetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<CalendarProbeController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Status Details'),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        foregroundColor: Colors.black87,
      ),
      body: Obx(() {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Real-time synchronization status for all sources',
                  style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 12),

              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('All Sources', style: TextStyle(fontWeight: FontWeight.w600)),
                                SizedBox(height: 4),
                                Text('Monitor each connected service', style: TextStyle(color: Colors.black54)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: ctrl.isSyncing.value ? null : () => ctrl.syncNow(),
                            icon: const Icon(Icons.refresh, size: 12),
                            label: const Text('Refresh All'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              backgroundColor: const Color(0xFF4F8A52),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // list of simplified source cards built from summary counts
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                      children: [
                        // If detailed logs exist, render per-source cards; otherwise render aggregated placeholders
                        ..._buildDetailCards(ctrl),
                      ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

enum _Status { synced, syncing, error }

Widget _sourceCard({
  required String title,
  required String subtitle,
  required _Status status,
  DateTime? last,
  VoidCallback? onRetry,
}) {
  Color borderColor;
  Color bgColor;
  Widget statusWidget;
  switch (status) {
    case _Status.synced:
      borderColor = Colors.green.shade100;
      bgColor = Colors.green.shade50;
      statusWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(8)),
        child: const Text('Synced', style: TextStyle(color: Colors.green, fontSize: 12)),
      );
      break;
    case _Status.syncing:
      borderColor = Colors.lightGreen.shade100;
      bgColor = Colors.lightGreen.shade50;
      statusWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.lightGreen.shade100, borderRadius: BorderRadius.circular(8)),
        child: const Text('Syncing', style: TextStyle(color: Colors.lightGreen, fontSize: 12)),
      );
      break;
    case _Status.error:
      borderColor = Colors.red.shade100;
      bgColor = Colors.red.shade50;
      statusWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8)),
        child: const Text('Error', style: TextStyle(color: Colors.red, fontSize: 12)),
      );
      break;
  }

  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: borderColor),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(8)),
          child: Icon(
            status == _Status.error ? Icons.error_outline : Icons.check_circle,
            color: status == _Status.error ? Colors.red : Colors.green,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(child: statusWidget),
                ],
              ),
              const SizedBox(height: 6),
              Text(subtitle, style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              Text('Last synced: ${last == null ? 'Never' : _formatRelative(last)}', style: const TextStyle(color: Colors.black45, fontSize: 12)),
            ],
          ),
        ),
        if (status == _Status.error)
          const SizedBox(width: 8),
        if (status == _Status.error)
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

String _formatRelative(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
  if (diff.inHours < 24) return '${diff.inHours} hours ago';
  return '${diff.inDays} days ago';
}

List<Widget> _buildDetailCards(CalendarProbeController ctrl) {
  final s = ctrl.summary.value;
  final List<Widget> cards = [];

  if (s != null && (s.successLog.isNotEmpty || s.errorLog.isNotEmpty)) {
    for (var name in s.successLog) {
      cards.add(_sourceCard(
        title: name,
        subtitle: 'Synced',
        status: _Status.synced,
        last: ctrl.lastSyncAt.value,
        onRetry: null,
      ));
      cards.add(const SizedBox(height: 8));
    }
    for (var err in s.errorLog) {
      cards.add(_sourceCard(
        title: err,
        subtitle: 'Error',
        status: _Status.error,
        last: ctrl.lastSyncAt.value,
        onRetry: ctrl.isSyncing.value ? null : () => ctrl.syncNow(),
      ));
      cards.add(const SizedBox(height: 8));
    }
  } else {
    // Fallback aggregated cards
    cards.add(_sourceCard(
      title: 'All Sources',
      subtitle: '${s?.total ?? 0} sources monitored',
      status: (ctrl.processing.value > 0) ? _Status.syncing : _Status.synced,
      last: ctrl.lastSyncAt.value,
      onRetry: null,
    ));
    cards.add(const SizedBox(height: 8));
    cards.add(_sourceCard(
      title: 'Successful',
      subtitle: '${s?.success ?? ctrl.success.value} sources synced',
      status: _Status.synced,
      last: ctrl.lastSyncAt.value,
      onRetry: null,
    ));
    cards.add(const SizedBox(height: 8));
    cards.add(_sourceCard(
      title: 'Errors',
      subtitle: '${s?.failed ?? ctrl.failed.value} sources',
      status: _Status.error,
      last: ctrl.lastSyncAt.value,
      onRetry: ctrl.isSyncing.value ? null : () => ctrl.syncNow(),
    ));
  }

  return cards;
}


