import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/models/client_bootstrap.dart';
import '../features/calendar/calendar_page.dart';
import '../features/chores/chores_page.dart';
import '../features/settings/settings_page.dart';
import '../features/tasks/tasks_page.dart';

class CaleeHomePage extends StatefulWidget {
  const CaleeHomePage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    this.onBootstrapRefreshed,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;
  final void Function(ClientBootstrap)? onBootstrapRefreshed;

  @override
  State<CaleeHomePage> createState() => _CaleeHomePageState();
}

class _CaleeHomePageState extends State<CaleeHomePage> {
  int _selectedIndex = 0;
  late final List<_CaleeTab> _tabs;

  bool get _hasChoreService => widget.bootstrap.services.any(
        (service) => service.supportsChores,
      );

  @override
  void initState() {
    super.initState();

    _tabs = [
      _CaleeTab(
        title: 'Calendar',
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
        page: CalendarPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.bootstrap.services,
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
        ),
      ),
      if (_hasChoreService)
        _CaleeTab(
          title: 'Chores',
          icon: Icons.family_restroom_outlined,
          selectedIcon: Icons.family_restroom,
          page: ChoresPage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
            services: widget.bootstrap.services,
            households: widget.bootstrap.contexts.households,
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
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tabs[_selectedIndex];

    return Scaffold(
      appBar: _selectedIndex == 0 ? null : AppBar(title: Text(tab.title)),
      body: tab.page,
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
