import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/models/cloud_provider.dart';
import '../core/models/app_theme_mode.dart';
import '../features/auth/auth_page.dart';
import '../features/auth/auth_state.dart';
import '../features/auth/password_reset_page.dart';
import '../features/camera/joblens_camera_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/projects/projects_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sync/provider_oauth_callback.dart';
import 'joblens_store.dart';

class JoblensApp extends ConsumerStatefulWidget {
  const JoblensApp({super.key});

  @override
  ConsumerState<JoblensApp> createState() => _JoblensAppState();
}

class _JoblensAppState extends ConsumerState<JoblensApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _appShellKey = GlobalKey<_AppShellState>();
  bool _showingPasswordRecovery = false;
  bool _showingAuthPrompt = false;
  int _handledReauthenticationRequest = 0;
  StreamSubscription<Uri>? _appLinkSubscription;
  String? _lastHandledProviderCallback;

  @override
  void initState() {
    super.initState();
    unawaited(_installAppLinkHandling());
  }

  @override
  void dispose() {
    unawaited(_appLinkSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateStreamProvider, (_, next) {
      if (!mounted) {
        return;
      }
      final authState = next.valueOrNull;
      debugPrint(
        'Joblens auth event: ${authState?.event.name ?? 'none'} '
        'user=${authState?.session?.user.id ?? 'none'}',
      );
      unawaited(
        ref.read(joblensStoreProvider).syncAuthSession(authState?.session),
      );

      if (authState?.event == AuthChangeEvent.passwordRecovery) {
        unawaited(_presentPasswordRecovery());
      }
    });
    ref.listen(joblensStoreListenableProvider, (_, next) {
      if (!mounted) {
        return;
      }
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

    final store = ref.watch(joblensStoreListenableProvider);
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF276749),
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF276749),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'Joblens',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      themeMode: switch (store.appThemeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      home: AppShell(key: _appShellKey),
    );
  }

  Future<void> _installAppLinkHandling() async {
    final appLinks = AppLinks();

    _appLinkSubscription = appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleIncomingUri(uri, source: 'stream')),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Joblens app-link stream error: $error\n$stackTrace');
      },
    );

    try {
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleIncomingUri(initialUri, source: 'initial');
      }
    } catch (error, stackTrace) {
      debugPrint('Joblens initial app-link error: $error\n$stackTrace');
    }
  }

  Future<void> _handleIncomingUri(Uri uri, {required String source}) async {
    if (!mounted) {
      return;
    }
    final callback = ProviderOAuthCallback.tryParse(uri);
    if (callback == null) {
      return;
    }

    final callbackKey = uri.toString();
    if (_lastHandledProviderCallback == callbackKey) {
      return;
    }
    _lastHandledProviderCallback = callbackKey;

    debugPrint(
      'Joblens provider callback ($source): '
      'provider=${callback.provider.key} status=${callback.status}',
    );

    final store = ref.read(joblensStoreProvider);
    try {
      if (callback.isSuccess) {
        debugPrint(
          'Joblens provider callback success: ${callback.provider.key}',
        );
        if (callback.sessionId != null && callback.sessionId!.isNotEmpty) {
          await store.completeProviderConnection(callback.sessionId!);
        } else {
          await store.backfillCloudSyncAfterProviderConnection();
        }
      } else {
        debugPrint(
          'Joblens provider callback error: ${callback.provider.key} '
          'code=${callback.code ?? 'unknown'} message=${callback.message ?? 'none'}',
        );
        await store.refresh();
      }
    } catch (error, stackTrace) {
      debugPrint('Joblens provider refresh failed: $error\n$stackTrace');
    }

    if (!mounted) {
      return;
    }
    _appShellKey.currentState?.showSettingsTab();
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(callback.userFacingMessage())),
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
  int _lastNonCameraTab = 1;
  final _nonCameraPages = const [GalleryPage(), ProjectsPage(), SettingsPage()];

  void showSettingsTab() {
    if (!mounted) {
      return;
    }
    setState(() {
      _lastNonCameraTab = 3;
      _currentTab = 3;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: _onTabSwipeEnd,
        child: _buildCurrentPage(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (index) {
          setState(() {
            if (index != 0) {
              _lastNonCameraTab = index;
            }
            _currentTab = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_camera_outlined),
            label: 'Camera',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.workspaces_outline),
            label: 'Projects',
          ),
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
    if (velocity <= -450 && _currentTab < 3) {
      setState(() {
        final nextTab = _currentTab + 1;
        if (nextTab != 0) {
          _lastNonCameraTab = nextTab;
        }
        _currentTab = nextTab;
      });
      return;
    }
    if (velocity >= 450 && _currentTab > 0) {
      setState(() {
        final nextTab = _currentTab - 1;
        if (nextTab != 0) {
          _lastNonCameraTab = nextTab;
        }
        _currentTab = nextTab;
      });
    }
  }

  Widget _buildCurrentPage() {
    if (_currentTab == 0) {
      return JoblensCameraPage(
        onSessionClosed: () {
          if (!mounted) {
            return;
          }
          setState(() {
            _currentTab = _lastNonCameraTab;
          });
        },
      );
    }
    return IndexedStack(index: _currentTab - 1, children: _nonCameraPages);
  }
}
