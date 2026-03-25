import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../common/utils/mmkv_utils.dart';
import '../feature/ios_caldav_setup_page.dart';
import '../feature/ios_external_calendar_import_page.dart';
import '../common/app_constant.dart';
import '../controllers/calendar_probe_controller.dart';
import '../sync/background_sync_scheduler.dart';

class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key, this.forceIosConnectionsMode});

  final bool? forceIosConnectionsMode;

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> with WidgetsBindingObserver {
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
  Completer<void>? _resumeCompleter;
  bool get _isIosConnectionsMode => widget.forceIosConnectionsMode ?? Platform.isIOS;
  bool get _showIosMigrationReminder {
    if (!_isIosConnectionsMode) return false;
    final deprecated = MMKVUtils.instance.getBool(AppConstant.iosLegacySyncDeprecatedKey, defaultValue: false) ?? false;
    final dismissed = MMKVUtils.instance.getBool(AppConstant.iosLegacySyncNoticeDismissedKey, defaultValue: false) ?? false;
    return deprecated && !dismissed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appVersionLabelFuture = _loadAppVersionLabel();
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeCompleter?.complete();
      _resumeCompleter = null;
    }
  }

  Future<void> _waitForAppResume({Duration timeout = const Duration(seconds: 90)}) async {
    _resumeCompleter = Completer<void>();
    await _resumeCompleter!.future.timeout(timeout, onTimeout: () {});
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
        _autoSyncEnabled = _isIosConnectionsMode ? false : autoSyncEnabled;
        _periodicSyncEnabled = _isIosConnectionsMode ? false : periodicSyncEnabled;
      });
    } catch (_) {}
  }

  Future<bool> _ensureBackgroundPermissionGranted() async {
    if (!Platform.isAndroid) {
      return true;
    }

    var status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) {
      return true;
    }

    status = await Permission.ignoreBatteryOptimizations.request();
    if (status.isGranted) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final shouldOpenSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow background running'),
        content: const Text(
          'To enable periodic background sync, please allow this app to run in the background (unrestricted battery/background activity) in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );

    if (shouldOpenSettings == true) {
      await openAppSettings();
      await _waitForAppResume();
      status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        return true;
      }
    }

    return false;
  }

  Future<void> _saveSettings() async {
    try {
      if (_isIosConnectionsMode) {
        MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, false);
        await BackgroundSyncScheduler.setPeriodicEnabled(false);
        if (Get.isRegistered<CalendarProbeController>()) {
          await Get.find<CalendarProbeController>().refreshOverviewState();
        }
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connections updated')));
        return;
      }

      if (_periodicSyncEnabled) {
        final hasPermission = await _ensureBackgroundPermissionGranted();
        if (!hasPermission) {
          if (!mounted) {
            return;
          }
          setState(() => _periodicSyncEnabled = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please grant background running permission before enabling periodic sync.')),
          );
          return;
        }
      }

      MMKVUtils.instance.setInt(AppConstant.syncIntervalCalendarKey, _calendarInterval);
      MMKVUtils.instance.setInt('sync_interval_tasks', _tasksInterval);
      MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, _autoSyncEnabled);
      await BackgroundSyncScheduler.setPeriodicEnabled(_periodicSyncEnabled);
      if (Get.isRegistered<CalendarProbeController>()) {
        await Get.find<CalendarProbeController>().refreshOverviewState();
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isIosConnectionsMode = _isIosConnectionsMode;
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
                  Text(isIosConnectionsMode ? 'Connections' : 'Synchronization', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  if (isIosConnectionsMode) ...[
                    if (_showIosMigrationReminder) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.1),
                          border: Border.all(color: Colors.amber.withOpacity(0.4)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'iPhone sync has moved to Apple Calendar account connections and imported read-only links.',
                        ),
                      ),
                    ],
                    const Text(
                      'CaleeSync no longer uses hidden app-level sync on iPhone.\n'
                      'Use Apple Calendar account connections for Calee two-way sync.\n'
                      'Use imported subscription calendars for iCloud, Google, and Outlook.',
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.phone_iphone),
                      title: const Text('Add Calee Calendar to iPhone'),
                      subtitle: const Text('Set up Apple Calendar two-way sync for Calee'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const IosCalDavSetupPage()),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_outlined),
                      title: const Text('Import iCloud / Google / Outlook into Calee'),
                      subtitle: const Text('Import a read-only iCloud, Google, or Outlook calendar into Calee'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const IosExternalCalendarImportPage()),
                    ),
                  ] else ...[
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
                      onChanged: (v) async {
                        if (!v) {
                          setState(() => _periodicSyncEnabled = false);
                          return;
                        }

                        final hasPermission = await _ensureBackgroundPermissionGranted();
                        if (!mounted) {
                          return;
                        }
                        setState(() => _periodicSyncEnabled = hasPermission);
                      },
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
                        onPressed: _saveSettings,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Save Settings', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
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
                  Text(
                    isIosConnectionsMode ? 'About iPhone Connections' : 'About Sync',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isIosConnectionsMode
                        ? 'Use Apple Calendar’s CalDAV account path for Calee two-way sync.\n'
                            'Use imported iCloud, Google, or Outlook links for read-only calendars inside Calee.\n'
                            'Imported calendars refresh periodically and are not two-way synced from Calee.'
                        : 'Calee automatically synchronizes your calendars and tasks with Google, iCloud, Outlook, and other connected services. When "Two-way sync" is enabled, changes made in either location will be synced bidirectionally. Otherwise, data is read-only in the respective location to prevent conflicts.',
                    style: const TextStyle(color: Colors.black54),
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
