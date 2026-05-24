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
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;

  @override
  State<CaleeHomePage> createState() => _CaleeHomePageState();
}

class _CaleeHomePageState extends State<CaleeHomePage> {
  int _selectedIndex = 0;

  List<_CaleeTab> get _tabs => [
        _CaleeTab(
          title: 'Calendar',
          icon: Icons.calendar_month_outlined,
          selectedIcon: Icons.calendar_month,
          page: CalendarPage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
          ),
        ),
        const _CaleeTab(
          title: 'Tasks',
          icon: Icons.checklist_outlined,
          selectedIcon: Icons.checklist,
          page: TasksPage(),
        ),
        const _CaleeTab(
          title: 'Chores',
          icon: Icons.family_restroom_outlined,
          selectedIcon: Icons.family_restroom,
          page: ChoresPage(),
        ),
        _CaleeTab(
          title: 'Settings',
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          page: SettingsPage(
            bootstrap: widget.bootstrap,
            onSignOut: widget.onSignOut,
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final tab = tabs[_selectedIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(tab.title),
      ),
      body: tab.page,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: tabs
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
