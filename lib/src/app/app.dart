import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/models/cloud_provider.dart';
import '../core/models/app_launch_destination.dart';
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

class _JoblensAppState extends ConsumerState<JoblensApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _appShellKey = GlobalKey<_AppShellState>();
  bool _showingPasswordRecovery = false;
  bool _showingAuthPrompt = false;
  int _handledReauthenticationRequest = 0;
  int _handledForcedSignOutNotice = 0;
  StreamSubscription<Uri>? _appLinkSubscription;
  RealtimeChannel? _deviceSessionChannel;
  String? _lastHandledProviderCallback;
  String? _listeningAuthSessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_installAppLinkHandling());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_appLinkSubscription?.cancel());
    unawaited(_disposeDeviceSessionChannel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || state != AppLifecycleState.resumed) {
      return;
    }
    unawaited(_handleAppResume());
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
      unawaited(_syncDeviceSessionChannel(authState?.session));

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
    ref.listen(joblensStoreListenableProvider, (_, next) {
      if (!mounted) {
        return;
      }
      final noticeCount = next.forcedSignOutNoticeCount;
      if (noticeCount <= _handledForcedSignOutNotice) {
        return;
      }
      _handledForcedSignOutNotice = noticeCount;
      final message =
          next.forcedSignOutMessage ?? 'You were signed out from another device.';
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    });

    final store = ref.watch(joblensStoreListenableProvider);
    final isAuthConfigured = ref.watch(authConfigurationProvider);
    final authState = ref.watch(authStateStreamProvider);
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
      home: _buildHome(
        authState: authState,
        isAuthConfigured: isAuthConfigured,
        store: store,
      ),
    );
  }

  Widget _buildHome({
    required AsyncValue<AuthState?> authState,
    required bool isAuthConfigured,
    required JoblensStore store,
  }) {
    if (!isAuthConfigured) {
      return AppShell(
        key: _appShellKey,
        initialLaunchDestination: store.appLaunchDestination,
      );
    }

    if (authState.isLoading && authState.valueOrNull == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final session = authState.valueOrNull?.session;
    if (session?.user == null) {
      return const AuthPage();
    }

    return AppShell(
      key: _appShellKey,
      initialLaunchDestination: store.launchDestinationForSession(
        isAuthenticated: true,
      ),
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

  Future<void> _handleAppResume() async {
    final authState = ref.read(authStateStreamProvider).valueOrNull;
    final session = authState?.session;
    if (session?.user == null) {
      await _disposeDeviceSessionChannel();
      return;
    }
    final store = ref.read(joblensStoreProvider);
    await store.registerCurrentDeviceSession();
    await store.checkCurrentSessionStatus();
  }

  Future<void> _syncDeviceSessionChannel(Session? session) async {
    final authSessionId = session == null
        ? null
        : _extractAuthSessionId(session.accessToken);
    if (authSessionId == _listeningAuthSessionId) {
      return;
    }

    await _disposeDeviceSessionChannel();
    _listeningAuthSessionId = authSessionId;
    if (authSessionId == null || authSessionId.isEmpty) {
      return;
    }

    final store = ref.read(joblensStoreProvider);
    final channel = Supabase.instance.client.channel(
      'device-session:$authSessionId',
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'device_auth_sessions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'auth_session_id',
        value: authSessionId,
      ),
      callback: (payload) {
        final newRecord = payload.newRecord;
        final status = newRecord['status']?.toString();
        if (status != null && status != 'active') {
          unawaited(store.checkCurrentSessionStatus());
        }
      },
    );
    channel.subscribe();
    _deviceSessionChannel = channel;
  }

  Future<void> _disposeDeviceSessionChannel() async {
    final channel = _deviceSessionChannel;
    _deviceSessionChannel = null;
    _listeningAuthSessionId = null;
    if (channel == null) {
      return;
    }
    await Supabase.instance.client.removeChannel(channel);
  }

  String? _extractAuthSessionId(String accessToken) {
    final parts = accessToken.split('.');
    if (parts.length < 2) {
      return null;
    }
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(normalized)),
      );
      if (payload is Map && payload['session_id'] is String) {
        return payload['session_id'] as String;
      }
    } catch (_) {
      // Ignore malformed access tokens and skip realtime subscription.
    }
    return null;
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
  const AppShell({super.key, required this.initialLaunchDestination});

  final AppLaunchDestination initialLaunchDestination;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _currentTab = _tabIndexForDestination(
    widget.initialLaunchDestination,
  );
  late int _lastNonCameraTab = _currentTab == 0 ? 1 : _currentTab;
  final _nonCameraPages = const [GalleryPage(), ProjectsPage(), SettingsPage()];
  late final PageController _nonCameraPageController;

  @override
  void initState() {
    super.initState();
    _nonCameraPageController = PageController(initialPage: _lastNonCameraTab - 1);
  }

  @override
  void dispose() {
    _nonCameraPageController.dispose();
    super.dispose();
  }

  void showSettingsTab() {
    if (!mounted) {
      return;
    }
    _selectTab(3);
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
        onDestinationSelected: _selectTab,
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
      _selectTab(_currentTab + 1);
      return;
    }
    if (velocity >= 450 && _currentTab > 0) {
      _selectTab(_currentTab - 1);
    }
  }

  void _selectTab(int index) {
    if (!mounted || index == _currentTab) {
      return;
    }

    setState(() {
      if (index != 0) {
        _lastNonCameraTab = index;
      }
      _currentTab = index;
    });

    if (index != 0 && _nonCameraPageController.hasClients) {
      _nonCameraPageController.jumpToPage(index - 1);
      return;
    }

    if (index != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_nonCameraPageController.hasClients) {
          return;
        }
        _nonCameraPageController.jumpToPage(index - 1);
      });
    }
  }

  Widget _buildCurrentPage() {
    if (_currentTab == 0) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildNonCameraPageView(),
          JoblensCameraPage(
            onSessionClosed: () {
              if (!mounted) {
                return;
              }
              _selectTab(_lastNonCameraTab);
            },
          ),
        ],
      );
    }
    return _buildNonCameraPageView();
  }

  Widget _buildNonCameraPageView() {
    return PageView(
      controller: _nonCameraPageController,
      physics: const NeverScrollableScrollPhysics(),
      children: _nonCameraPages,
    );
  }

  static int _tabIndexForDestination(AppLaunchDestination destination) {
    return switch (destination) {
      AppLaunchDestination.camera => 0,
      AppLaunchDestination.projects => 2,
    };
  }
}
