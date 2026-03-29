import 'package:caleesync/controllers/calendar_share_alias_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class CalendarShareAliasPage extends StatelessWidget {
  const CalendarShareAliasPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.put(CalendarShareAliasController());

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'Calendar Share Alias',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
      ),
      body: Obx(() {
        if (ctrl.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        if (ctrl.error.value.isNotEmpty && ctrl.alias.value == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ctrl.error.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: ctrl.load,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final alias = ctrl.alias.value;
        return RefreshIndicator(
          onRefresh: ctrl.refreshAlias,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Calendar Share Alias',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Alias email',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        alias?.aliasEmail ?? '-',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.copy_outlined),
                              label: const Text('Copy'),
                              onPressed: alias == null
                                  ? null
                                  : () async {
                                      await ctrl.copyAlias();
                                      Get.snackbar(
                                        'Success',
                                        'Alias copied',
                                        snackPosition: SnackPosition.BOTTOM,
                                      );
                                    },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: ctrl.isRotating.value
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: const Text('Rotate'),
                              onPressed: ctrl.isRotating.value
                                  ? null
                                  : () async {
                                      final ok = await ctrl.rotateAlias();
                                      if (ok) {
                                        Get.snackbar(
                                          'Success',
                                          'Alias rotated',
                                          snackPosition: SnackPosition.BOTTOM,
                                        );
                                      } else if (ctrl.error.value.isNotEmpty) {
                                        Get.snackbar(
                                          'Error',
                                          ctrl.error.value,
                                          snackPosition: SnackPosition.BOTTOM,
                                          backgroundColor: Colors.red.shade50,
                                        );
                                      }
                                    },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Rotating changes your receive address for future shared-calendar emails.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('Share your calendar to this email address'),
                      SizedBox(height: 8),
                      Text('Outlook shared calendar emails are supported'),
                      SizedBox(height: 8),
                      Text('Imported calendars will appear in your normal calendar list'),
                    ],
                  ),
                ),
              ),
              if (ctrl.error.value.isNotEmpty && ctrl.alias.value != null) ...[
                const SizedBox(height: 16),
                Text(
                  ctrl.error.value,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        );
      }),
    );
  }
}
