import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/auth_page.dart';
import '../features/auth/auth_state.dart';
import '../features/auth/password_reset_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/projects/projects_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sync/sync_page.dart';
import 'joblens_store.dart';

class JoblensApp extends ConsumerStatefulWidget {
  const JoblensApp({super.key});

  @override
  ConsumerState<JoblensApp> createState() => _JoblensAppState();
}

class _JoblensAppState extends ConsumerState<JoblensApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _showingPasswordRecovery = false;
  bool _showingAuthPrompt = false;
  int _handledReauthenticationRequest = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateStreamProvider, (_, next) {
      final authState = next.valueOrNull;
      unawaited(
        ref.read(joblensStoreProvider).syncAuthSession(authState?.session),
      );

      if (authState?.event == AuthChangeEvent.passwordRecovery) {
        unawaited(_presentPasswordRecovery());
      }
    });
    ref.listen(joblensStoreListenableProvider, (_, next) {
      final requestCount = next.reauthenticationRequestCount;
      if (requestCount <= _handledReauthenticationRequest) {
        return;
      }
      _handledReauthenticationRequest = requestCount;
      if (!ref.read(authConfigurationProvider)) {
        return;
      }
      unawaited(_presentAuthPrompt());
    });

    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF276749));

    return MaterialApp(
      navigatorKey: _navigatorKey,
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

  Future<void> _presentPasswordRecovery() async {
    if (_showingPasswordRecovery) {
      return;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    _showingPasswordRecovery = true;
    try {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const PasswordResetPage(),
          fullscreenDialog: true,
        ),
      );
    } finally {
      _showingPasswordRecovery = false;
    }
  }

  Future<void> _presentAuthPrompt() async {
    if (_showingAuthPrompt || _showingPasswordRecovery) {
      return;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return;
    }

    _showingAuthPrompt = true;
    try {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const AuthPage(),
          fullscreenDialog: true,
        ),
      );
    } finally {
      _showingAuthPrompt = false;
    }
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
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: _onTabSwipeEnd,
        child: IndexedStack(index: _currentTab, children: _pages),
      ),
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

  void _onTabSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity <= -450 && _currentTab < _pages.length - 1) {
      setState(() {
        _currentTab += 1;
      });
      return;
    }
    if (velocity >= 450 && _currentTab > 0) {
      setState(() {
        _currentTab -= 1;
      });
    }
  }
}
