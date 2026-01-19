import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/home/sync_settings_page.dart';
import 'package:caleesync/home/task_lists_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../data/SyncEngine.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../test/UnifiedSyncTestPage.dart';
import 'calendars_page.dart';
import 'dashboard_page.dart';

class CalendarProbePage extends StatefulWidget {
  const CalendarProbePage({super.key});

  @override
  State<CalendarProbePage> createState() => _CalendarProbePageState();
}

class _CalendarProbePageState extends State<CalendarProbePage> {
  int _selectedIndex = 0;
  final SyncRepository _repo = SyncRepository();

  final List<Widget> _pages = const [
    DashboardPage(),
    CalendarsPage(),
    TaskListsPage(),
    SyncSettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    // 关键：在第一帧之后触发权限请求
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestCalendarPermission();
    });
  }

  Future<void> _requestCalendarPermission() async {
    // 1. 根据平台选择最准确的权限类型
    // iOS 17+ 必须使用 calendarFullAccess 才能读取系统事件
    Permission calendarPermission = Permission.calendarFullAccess;

    // 2. 检查当前状态
    var status = await calendarPermission.status;

    if (status.isPermanentlyDenied) {
      // 如果用户之前永久拒绝了，直接弹窗引导去系统设置
      _showSettingsDialog();
      return;
    }

    // 3. 发起请求
    status = await calendarPermission.request();

    // 4. 处理结果
    if (status.isGranted) {
      print("✅ 日历读写权限已授予");
      // 权限成功后，建议先刷新本地日历列表，再执行重置或同步
      await _repo.scanLocalCalendars(MMKVUtils.instance.getString(AppConstant.loginName)!);
      // _nuclearReset();
    } else if (status.isLimited) {
      // iOS 特有：受限访问（通常对你的同步 App 来说是不够的）
      print("⚠️ 权限受限，可能无法读取所有日历");
    } else {
      print("❌ 权限被拒绝: $status");
      _showPermissionDialog();
    }
  }

  void _showSettingsDialog() {
    // 引导用户跳转到手机设置页面
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("需要权限"),
        content: const Text("同步功能需要日历完整访问权限，请在设置中开启。"),
        actions: [
          TextButton(onPressed: () => openAppSettings(), child: const Text("去设置")),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
        ],
      ),
    );
  }

  Future<void> _nuclearReset() async {
    await DatabaseHelper.instance.deleteMyDatabase(); // 调用我之前给你写的物理删除方法
    print("☢️ 数据库物理文件已删除，请重启 App 后再试");
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("权限请求"),
        content: const Text("同步功能需要日历访问权限，请在设置中开启。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => openAppSettings(), // 打开系统设置
            child: const Text("去设置"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2C2C2E), // Dark gray background
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
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Text(
                    'C',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Calee',
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
            child: ElevatedButton.icon(
            onPressed: () async {
              final engine = SyncEngine();
              await engine.executeFullSync(onProgress: (summary) {
                print("进度更新: 成功 ${summary.success}, 失败 ${summary.failed}, 正在处理 ${summary.processing}");
                // 这里调用 setState(() => _mySummary = summary); 即可更新 UI
              });
            },
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Sync'),
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
            ),
          ),
        ],
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Top navigation icons row
          _buildBottomNavigation(),
          // Main content area
          Expanded(
            child: _pages[_selectedIndex],
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
                      child: const Center(
                        child: Text(
                          'C',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Calee',
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
                context.go(RouteConstant.profile);
              },
            ),
            _drawerItem(
              icon: Icons.qr_code_2_outlined,
              label: 'Link a device',
              onTap: () {},
            ),
            _drawerItem(
              icon: Icons.shield_outlined,
              label: 'Manage devices',
              onTap: () {},
            ),
            const Spacer(),
            _buildSyncButton(),
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

  Widget _buildSyncButton() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0D0C14),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              )
            ],
          ),
          child: ElevatedButton.icon(
            onPressed: () {
              // TODO: Sync action
            },
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.sync, size: 18),
            label: const Text(
              'Sync Now',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNavigation() {
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
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _selectedIndex == index;
    // Last item (Sync Settings) should have dark background when selected
    final isLastItem = index == 3;
    
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
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

