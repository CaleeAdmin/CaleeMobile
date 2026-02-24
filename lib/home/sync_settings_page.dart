import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../common/utils/mmkv_utils.dart';
import '../common/app_constant.dart';
import '../sync/background_sync_scheduler.dart';

class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final List<Map<String, dynamic>> _intervalOptions = const [
    {'label': 'Every 15 minutes', 'minutes': 15},
    {'label': 'Every 30 minutes', 'minutes': 30},
    {'label': 'Every hour', 'minutes': 60},
    {'label': 'Every 6 hours', 'minutes': 360},
    {'label': 'Every 24 hours', 'minutes': 1440},
  ];

  int _calendarInterval = 15;
  int _tasksInterval = 30;
  bool _autoSyncEnabled = true;
  bool _periodicSyncEnabled = false;
  late final Future<String> _appVersionLabelFuture;

  @override
  void initState() {
    super.initState();
    _appVersionLabelFuture = _loadAppVersionLabel();
    _loadSettings();
  }


  Future<String> _loadAppVersionLabel() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return 'Version ${packageInfo.version} (${packageInfo.buildNumber})';
  }

  void _loadSettings() {
    try {
      int valCal = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;
      int valTask = MMKVUtils.instance.getInt('sync_interval_tasks') ?? 30;
      final bool autoSyncEnabled = MMKVUtils.instance.getBool(AppConstant.autoSyncEnabledKey, defaultValue: true) ?? true;
      final bool periodicSyncEnabled = MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false;
      // validate against available options to avoid Dropdown assertion errors
      final validMinutes = _intervalOptions.map((e) => e['minutes'] as int).toSet();
      if (!validMinutes.contains(valCal) || valCal <= 0) valCal = 15;
      if (!validMinutes.contains(valTask) || valTask <= 0) valTask = 30;
      setState(() {
        _calendarInterval = valCal;
        _tasksInterval = valTask;
        _autoSyncEnabled = autoSyncEnabled;
        _periodicSyncEnabled = periodicSyncEnabled;
      });
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      MMKVUtils.instance.setInt(AppConstant.syncIntervalCalendarKey, _calendarInterval);
      MMKVUtils.instance.setInt('sync_interval_tasks', _tasksInterval);
      MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, _autoSyncEnabled);
      await BackgroundSyncScheduler.setPeriodicEnabled(_periodicSyncEnabled);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Synchronization', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text('Configure how often your calendars and tasks sync with their sources', style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Foreground Auto Sync', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Trigger sync on meaningful changes while app is active'),
                    value: _autoSyncEnabled,
                    onChanged: (v) => setState(() => _autoSyncEnabled = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Periodic Background Sync', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Run periodic sync when network is available'),
                    value: _periodicSyncEnabled,
                    onChanged: (v) => setState(() => _periodicSyncEnabled = v),
                  ),

                  const Text('Calendar Sync Interval', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _calendarInterval,
                    items: _intervalOptions.map((opt) {
                      return DropdownMenuItem<int>(value: opt['minutes'] as int, child: Text(opt['label'] as String));
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _calendarInterval = v);
                    },
                    decoration: InputDecoration(
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('More frequent syncing may impact battery life on mobile devices', style: TextStyle(color: Colors.black54, fontSize: 12)),
                  const SizedBox(height: 16),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _saveSettings(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Save Settings',style: TextStyle(color: Colors.white),),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('About Sync', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                    'Calee automatically synchronizes your calendars and tasks with Google, iCloud, Outlook, and other connected services. When "Two-way sync" is enabled, changes made in either location will be synced bidirectionally. Otherwise, data is read-only in the respective location to prevent conflicts.',
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<String>(
                    future: _appVersionLabelFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const SizedBox.shrink();
                      }

                      return Text(
                        snapshot.data!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black45,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
