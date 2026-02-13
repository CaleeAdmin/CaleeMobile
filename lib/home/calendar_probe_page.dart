import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/home/sync_settings_page.dart';
import 'package:caleesync/home/task_lists_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../data/SyncEngine.dart';
import '../controllers/calendar_probe_controller.dart';
import '../data/sync_repository.dart';
import 'DashboardPage.dart';
import 'CalendarPage.dart';
import '../feature/link_device_page.dart';

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
    TaskListsPage(),
    SyncSettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
  }

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
                  color: const Color(0xFF2E7AFE),
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GetX<CalendarProbeController>(
              init: CalendarProbeController(),
              builder: (ctrl) {
                return ElevatedButton.icon(
                  onPressed: ctrl.isSyncing.value ? null : () async {
                    try {
                      await ctrl.syncNow();
                      Get.snackbar('Sync', 'Sync completed', snackPosition: SnackPosition.BOTTOM);
                    } catch (e) {
                      Get.snackbar('Sync', 'Sync failed: $e', snackPosition: SnackPosition.BOTTOM);
                    }
                  },
                  icon: const Icon(Icons.sync, size: 18),
                  label: Text(ctrl.isSyncing.value ? 'Syncing...' : 'Sync'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(0, 36),
                  ),
                );
              },
            ),
          ),
        ],
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Top navigation icons row
          _buildBottomNavigation(),
          // Main content area - use IndexedStack to preserve state of pages and avoid re-initialization
          Expanded(
            child: Obx(() => IndexedStack(
                  index: _ctrl.selectedIndex.value,
                  children: _pages,
                )),
          ),
        ],
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
                        color: const Color(0xFF2E7AFE),
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
            // _drawerItem(
            //   icon: Icons.shield_outlined,
            //   label: 'Manage devices',
            //   onTap: () {},
            // ),
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

  Widget _buildBottomNavigation() {
    return Obx(() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(Icons.dashboard_outlined, 'Dashboard', 0),
          _buildNavItem(Icons.calendar_today_outlined, 'Calendars', 1),
          _buildNavItem(Icons.checklist_outlined, 'Task Lists', 2),
          _buildNavItem(Icons.settings, 'Sync Settings', 3),
        ],
      ),
    );
    });
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _ctrl.selectedIndex.value == index;
    // Last item (Sync Settings) should have dark background when selected
    final isLastItem = index == 3;
    
    return GestureDetector(
      onTap: () {
        _ctrl.setSelectedIndex(index);
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected 
              ? (isLastItem ? const Color(0xFF1A1A1C) : Colors.black87)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: isSelected 
              ? Colors.white 
              : (isLastItem && !isSelected ? Colors.black54 : Colors.black54),
          size: 24,
        ),
      ),
    );
  }
}
