import 'package:flutter/material.dart';

import '../features/gallery/gallery_page.dart';
import '../features/projects/projects_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sync/sync_page.dart';

class JoblensApp extends StatelessWidget {
  const JoblensApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF276749));

    return MaterialApp(
      title: 'Joblens',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentTab = 0;

  final _pages = const [
    GalleryPage(),
    ProjectsPage(),
    SyncPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentTab, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (index) {
          setState(() {
            _currentTab = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.workspaces_outline),
            label: 'Projects',
          ),
          NavigationDestination(icon: Icon(Icons.sync_outlined), label: 'Sync'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
