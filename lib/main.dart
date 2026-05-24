import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CaleeMobileApp());
}

class CaleeMobileApp extends StatelessWidget {
  const CaleeMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.lightGreen,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3FAF3),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3FAF3),
          foregroundColor: Color(0xFF1B5E20),
        ),
        cardColor: Colors.white,
        useMaterial3: true,
      ),
      home: const CaleeMobileHomePage(),
    );
  }
}

class CaleeMobileHomePage extends StatefulWidget {
  const CaleeMobileHomePage({super.key});

  @override
  State<CaleeMobileHomePage> createState() => _CaleeMobileHomePageState();
}

class _CaleeMobileHomePageState extends State<CaleeMobileHomePage> {
  int _selectedIndex = 0;

  static const List<_HomeTab> _tabs = [
    _HomeTab(
      title: 'Calendar',
      message: 'Calendar screen coming next',
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month,
    ),
    _HomeTab(
      title: 'Tasks',
      message: 'Tasks screen coming next',
      icon: Icons.checklist_outlined,
      selectedIcon: Icons.checklist,
    ),
    _HomeTab(
      title: 'Chores',
      message: 'Chores screen coming next',
      icon: Icons.family_restroom_outlined,
      selectedIcon: Icons.family_restroom,
    ),
    _HomeTab(
      title: 'Settings',
      message: 'Settings screen coming next',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final tab = _tabs[_selectedIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text(tab.title),
      ),
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              tab.message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
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

class _HomeTab {
  const _HomeTab({
    required this.title,
    required this.message,
    required this.icon,
    required this.selectedIcon,
  });

  final String title;
  final String message;
  final IconData icon;
  final IconData selectedIcon;
}
