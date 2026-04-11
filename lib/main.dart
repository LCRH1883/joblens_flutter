import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app/app.dart';
import 'src/app/joblens_store.dart';
import 'src/core/api/backend_auth.dart';
import 'src/core/api/joblens_backend_api_client.dart';
import 'src/core/config/app_runtime_configuration.dart';
import 'src/core/api/signed_media_url_cache.dart';
import 'src/core/db/app_database.dart';
import 'src/core/storage/media_storage_service.dart';
import 'src/core/sync/sync_service.dart';
import 'src/features/auth/auth_state.dart';
import 'src/features/camera/camera_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = await AppRuntimeConfiguration.load();
  await _runJoblensApp(config);
}

Future<void> _runJoblensApp(AppRuntimeConfiguration config) async {
  if (config.isConfigured) {
    await Supabase.initialize(
      url: config.supabaseUrl,
      anonKey: config.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: true,
        detectSessionInUri: true,
      ),
    );
  }

  List<CameraDescription> cameras;
  try {
    cameras = await availableCameras().timeout(const Duration(seconds: 4));
  } catch (_) {
    cameras = const [];
  }
  final database = await AppDatabase.open();
  final mediaStorage = await MediaStorageService.create();
  final backendTokenProvider = config.isConfigured
      ? const SupabaseAccessTokenProvider()
      : const NullAccessTokenProvider();
  final backendApiClient = JoblensBackendApiClient(
    baseUrl: config.apiBaseUrl,
    accessTokenProvider: backendTokenProvider,
  );
  final signedMediaUrlCache = SignedMediaUrlCache();
  final syncService = SyncService(
    database,
    backendApiClient: backendApiClient,
    signedMediaUrlCache: signedMediaUrlCache,
    mediaStorage: mediaStorage,
  );
  final store = JoblensStore(
    database: database,
    mediaStorage: mediaStorage,
    syncService: syncService,
    currentAuthUserIdProvider: config.isConfigured
        ? () => Supabase.instance.client.auth.currentUser?.id
        : null,
    signOutAction: config.isConfigured
        ? () => Supabase.instance.client.auth.signOut(scope: SignOutScope.local)
        : null,
  );

  await store.initialize();

  final app = ProviderScope(
    overrides: [
      joblensStoreProvider.overrideWithValue(store),
      availableCamerasProvider.overrideWithValue(cameras),
      authConfigurationProvider.overrideWithValue(config.isConfigured),
      appRuntimeConfigurationProvider.overrideWithValue(config),
    ],
    child: const JoblensApp(),
  );
  runApp(app);
}
