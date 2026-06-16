import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/models/client_bootstrap.dart';
import '../features/calendar/calendar_page.dart';
import '../features/chores/chores_page.dart';
import '../features/settings/settings_page.dart';
import '../features/tasks/tasks_page.dart';
import '../features/today/today_page.dart';

class CaleeHomePage extends StatefulWidget {
  const CaleeHomePage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    this.onBootstrapRefreshed,
    this.initialSelectedIndex = 0,
    this.onInitialTabConsumed,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;
  final void Function(ClientBootstrap)? onBootstrapRefreshed;
  final int initialSelectedIndex;
  // Called once after the first frame when initialSelectedIndex != 0,
  // so callers can clear any one-shot tab override.
  final VoidCallback? onInitialTabConsumed;

  @override
  State<CaleeHomePage> createState() => _CaleeHomePageState();
}

class _CaleeHomePageState extends State<CaleeHomePage> {
  late int _selectedIndex;
  late final List<_CaleeTab> _tabs;

  bool get _hasChoreService =>
      widget.bootstrap.services.any((service) => service.supportsChores);

  bool get _selectedTabOwnsTopBar {
    final title = _tabs[_selectedIndex].title;
    return title == 'Today' ||
        title == 'Calendar' ||
        title == 'Tasks' ||
        title == 'Chores';
  }

  // Tab index helpers (computed after _tabs is built)
  int get _calendarTabIndex => _tabs.indexWhere((t) => t.title == 'Calendar');
  int get _tasksTabIndex => _tabs.indexWhere((t) => t.title == 'Tasks');
  int get _choresTabIndex => _tabs.indexWhere((t) => t.title == 'Chores');

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialSelectedIndex;

    if (widget.initialSelectedIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onInitialTabConsumed?.call();
      });
    }

    _tabs = [
      _CaleeTab(
        title: 'Today',
        icon: Icons.today_outlined,
        selectedIcon: Icons.today,
        page: TodayPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.bootstrap.services,
          households: widget.bootstrap.contexts.households,
          onNavigateToCalendar: () =>
              setState(() => _selectedIndex = _calendarTabIndex),
          onNavigateToTasks: () =>
              setState(() => _selectedIndex = _tasksTabIndex),
          onNavigateToChores: _hasChoreService
              ? () => setState(() => _selectedIndex = _choresTabIndex)
              : null,
        ),
      ),
      _CaleeTab(
        title: 'Calendar',
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
        page: CalendarPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.bootstrap.services,
          accountId: widget.bootstrap.account.id,
        ),
      ),
      _CaleeTab(
        title: 'Tasks',
        icon: Icons.checklist_outlined,
        selectedIcon: Icons.checklist,
        page: TasksPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.bootstrap.services,
          accountId: widget.bootstrap.account.id,
        ),
      ),
      if (_hasChoreService)
        _CaleeTab(
          title: 'Chores',
          icon: Icons.cleaning_services_outlined,
          selectedIcon: Icons.cleaning_services,
          page: ChoresPage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
            services: widget.bootstrap.services,
            households: widget.bootstrap.contexts.households,
            accountId: widget.bootstrap.account.id,
          ),
        ),
      _CaleeTab(
        title: 'Settings',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        page: SettingsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          bootstrap: widget.bootstrap,
          onSignOut: widget.onSignOut,
          onBootstrapRefreshed: widget.onBootstrapRefreshed,
          onNavigateToCalendar: () =>
              setState(() => _selectedIndex = _calendarTabIndex),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectedTabOwnsTopBar
          ? null
          : AppBar(title: Text(_tabs[_selectedIndex].title)),
      body: IndexedStack(
        index: _selectedIndex,
        children: _tabs.map((tab) => tab.page).toList(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: _tabs
            .map(
              (tab) => NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.title,
              ),
            )
            .toList(),
      ),
    );
  }
}

class _CaleeTab {
  const _CaleeTab({
    required this.title,
    required this.icon,
    required this.selectedIcon,
    required this.page,
  });

  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final Widget page;
}
