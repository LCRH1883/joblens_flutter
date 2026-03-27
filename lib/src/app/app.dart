import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/auth_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/projects/projects_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sync/sync_page.dart';
import 'joblens_store.dart';

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
      home: const AuthGate(),
    );
  }
}

class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  late final Stream<AuthState> _authStateChanges;
  Session? _session;
  bool _isSynchronizingSession = false;

  @override
  void initState() {
    super.initState();
    _session = Supabase.instance.client.auth.currentSession;
    _authStateChanges = Supabase.instance.client.auth.onAuthStateChange;
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);

    return StreamBuilder<AuthState>(
      stream: _authStateChanges,
      initialData: AuthState(AuthChangeEvent.initialSession, _session),
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? _session;
        if (session != _session) {
          _session = session;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _handleSessionChange(session);
          });
        }

        if (store.isLoading || _isSynchronizingSession) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (session == null) {
          return const AuthPage();
        }

        return const AppShell();
      },
    );
  }

  Future<void> _handleSessionChange(Session? session) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isSynchronizingSession = true;
    });
    try {
      await ref.read(joblensStoreProvider).syncAuthSession(session);
    } finally {
      if (mounted) {
        setState(() {
          _isSynchronizingSession = false;
        });
      }
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
