import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/models/client_bootstrap.dart';
import '../features/calendar/calendar_page.dart';
import '../features/chores/chores_page.dart';
import '../features/meals/meals_page.dart';
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
  int _calendarRefreshGeneration = 0;

  bool get _hasChoreService =>
      widget.bootstrap.isFamilyUxContext &&
      widget.bootstrap.services.any((s) => s.isActive && s.supportsChores);

  bool get _hasMealsService {
    if (!widget.bootstrap.isFamilyUxContext) return false;
    final portal = widget.bootstrap.services
        .where((s) => s.id == 'portal')
        .firstOrNull;
    if (portal != null && portal.isActive && portal.supportsMeals) return true;
    return widget.bootstrap.services.any((s) => s.isActive && s.supportsMeals);
  }

  bool get _selectedTabOwnsTopBar {
    final title = _tabs[_selectedIndex].title;
    return title == 'Today' ||
        title == 'Calendar' ||
        title == 'Tasks' ||
        title == 'Chores' ||
        title == 'Meals';
  }

  // Tab index helpers (computed after _tabs is built)
  int get _calendarTabIndex => _tabs.indexWhere((t) => t.title == 'Calendar');
  int get _tasksTabIndex => _tabs.indexWhere((t) => t.title == 'Tasks');
  int get _mealsTabIndex => _tabs.indexWhere((t) => t.title == 'Meals');

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
      const _CaleeTab(
        title: 'Today',
        icon: Icons.today_outlined,
        selectedIcon: Icons.today,
      ),
      const _CaleeTab(
        title: 'Calendar',
        icon: Icons.calendar_month_outlined,
        selectedIcon: Icons.calendar_month,
      ),
      const _CaleeTab(
        title: 'Tasks',
        icon: Icons.checklist_outlined,
        selectedIcon: Icons.checklist,
      ),
      if (_hasChoreService)
        const _CaleeTab(
          title: 'Chores',
          icon: Icons.cleaning_services_outlined,
          selectedIcon: Icons.cleaning_services,
        ),
      if (_hasMealsService)
        const _CaleeTab(
          title: 'Meals',
          icon: Icons.restaurant_menu_outlined,
          selectedIcon: Icons.restaurant_menu,
        ),
      const _CaleeTab(
        title: 'Settings',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  @override
  void didUpdateWidget(CaleeHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newIndex = widget.initialSelectedIndex;
    if (newIndex != oldWidget.initialSelectedIndex && newIndex != 0) {
      final clamped = newIndex.clamp(0, _tabs.length - 1).toInt();
      setState(() {
        _selectedIndex = clamped;
        if (clamped == _calendarTabIndex) {
          _calendarRefreshGeneration++;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onInitialTabConsumed?.call();
      });
    }
  }

  List<Widget> _buildPages() {
    return [
      TodayPage(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        services: widget.bootstrap.services,
        households: widget.bootstrap.contexts.households,
        isFamilyUxContext: widget.bootstrap.isFamilyUxContext,
        onNavigateToCalendar: () =>
            setState(() => _selectedIndex = _calendarTabIndex),
        onNavigateToTasks: () =>
            setState(() => _selectedIndex = _tasksTabIndex),
        onNavigateToMeals: _hasMealsService
            ? () => setState(() => _selectedIndex = _mealsTabIndex)
            : null,
      ),
      CalendarPage(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        services: widget.bootstrap.services,
        accountId: widget.bootstrap.account.id,
        isFamilyUxContext: widget.bootstrap.isFamilyUxContext,
        refreshGeneration: _calendarRefreshGeneration,
      ),
      TasksPage(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        services: widget.bootstrap.services,
        accountId: widget.bootstrap.account.id,
        isFamilyUxContext: widget.bootstrap.isFamilyUxContext,
      ),
      if (_hasChoreService)
        ChoresPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.bootstrap.services,
          households: widget.bootstrap.contexts.households,
          accountId: widget.bootstrap.account.id,
        ),
      if (_hasMealsService)
        MealsPage(hubClient: widget.hubClient, accessToken: widget.accessToken),
      SettingsPage(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        bootstrap: widget.bootstrap,
        onSignOut: widget.onSignOut,
        onBootstrapRefreshed: widget.onBootstrapRefreshed,
        onNavigateToCalendar: () => setState(() {
          _selectedIndex = _calendarTabIndex;
          _calendarRefreshGeneration++;
        }),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectedTabOwnsTopBar
          ? null
          : AppBar(title: Text(_tabs[_selectedIndex].title)),
      body: IndexedStack(index: _selectedIndex, children: _buildPages()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
            // Calendar keeps its controller alive in the IndexedStack, so a
            // plain tab switch would otherwise show stale First Day of
            // Week / Time Format / Default Calendar values after a Settings
            // change. Force a reload every time the tab becomes selected.
            if (index == _calendarTabIndex) {
              _calendarRefreshGeneration++;
            }
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
  });

  final String title;
  final IconData icon;
  final IconData selectedIcon;
}
