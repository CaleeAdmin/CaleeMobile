import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/home/sync_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../controllers/calendar_probe_controller.dart';
import 'DashboardPage.dart';
import 'CalendarPage.dart';
import '../feature/link_device_page.dart';
import 'sync_status_details_page.dart';

class CalendarProbePage extends StatefulWidget {
  const CalendarProbePage({super.key});

  @override
  State<CalendarProbePage> createState() => _CalendarProbePageState();
}

class _CalendarProbePageState extends State<CalendarProbePage> {
  final CalendarProbeController _ctrl = Get.put(CalendarProbeController());
  final List<Widget> _pages = const [
    DashboardPage(),
    CalendarPage(),
    SyncSettingsPage(),
  ];


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.black87),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF66BB6A),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Image(
                    image: AssetImage('assets/images/logo.png'),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'CaleeSync',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
        ),
        centerTitle: true,
        actions: [
          Obx(() {
            final isSyncing = _ctrl.isRunActive;

            return IconButton(
              tooltip: isSyncing ? 'View Activity' : 'Sync Now',
              onPressed: () async {
                if (!isSyncing) {
                  await _ctrl.refreshPagesBeforeSync();
                  await _ctrl.syncNow();
                  return;
                }
                Get.to(() => const SyncStatusDetailsPage());
              },
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                child: isSyncing
                    ? const SizedBox(
                        key: ValueKey('sync-progress'),
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.sync,
                        key: ValueKey('sync-icon'),
                        color: Colors.black87,
                      ),
              ),
            );
          }),
        ],
      ),
      body: Obx(() => IndexedStack(
            index: _ctrl.selectedIndex.value,
            children: _pages,
          )),
      bottomNavigationBar: Obx(
        () => NavigationBar(
          selectedIndex: _ctrl.selectedIndex.value,
          onDestinationSelected: _ctrl.setSelectedIndex,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_today),
              label: 'Calendars',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Sync Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      elevation: 12,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 104,
              child: DrawerHeader(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF66BB6A),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: const Padding(
                        padding: EdgeInsets.all(7),
                        child: Image(
                          image: AssetImage('assets/images/logo.png'),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'CaleeSync',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _drawerItem(
              icon: Icons.person_outline,
              label: 'Profile',
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                Get.toNamed(RouteConstant.profile);
              },
            ),
            _drawerItem(
              icon: Icons.security_outlined,
              label: 'Security',
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                Get.toNamed(RouteConstant.security);
              },
            ),
            _drawerItem(
              icon: Icons.qr_code_2_outlined,
              label: 'Link a device',
              onTap: () {
                Navigator.of(context).pop(); // Close drawer
                Get.to(() => const LinkDevicePage());
              },
            ),
            _drawerItem(
              icon: Icons.cloud_outlined,
              label: 'CalDav',
              onTap: () {
                Navigator.of(context).pop();
                _showCalDavPanel();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCalDavPanel() {
    final String server = (MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer).trim();
    final String username = (MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '').trim();
    final String password = (MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '').trim();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CalDav',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                _copyableField(label: 'Server', value: server),
                _copyableField(label: 'Username', value: username),
                _copyableField(label: 'Password', value: password),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _copyableField({required String label, required String value}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectionArea(
                    child: SelectableText(
                      value.isEmpty ? '-' : value,
                      style: const TextStyle(fontSize: 15, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy $label',
              onPressed: value.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: value));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$label copied')),
                      );
                    },
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: Colors.black87, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
