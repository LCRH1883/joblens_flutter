import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app/app.dart';
import 'src/app/joblens_store.dart';
import 'src/core/api/backend_auth.dart';
import 'src/core/api/joblens_backend_api_client.dart';
import 'src/core/api/signed_media_url_cache.dart';
import 'src/core/db/app_database.dart';
import 'src/core/storage/media_storage_service.dart';
import 'src/core/sync/credential_store.dart';
import 'src/core/sync/oauth/oauth_service.dart';
import 'src/core/sync/sync_service.dart';
import 'src/features/camera/camera_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const supabaseUrl = String.fromEnvironment('JOBLENS_SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('JOBLENS_SUPABASE_ANON_KEY');
  const configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
    throw StateError(
      'Missing Supabase configuration. Provide JOBLENS_SUPABASE_URL and JOBLENS_SUPABASE_ANON_KEY via --dart-define.',
    );
  }
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = const [];
  }
  final database = await AppDatabase.open();
  final mediaStorage = await MediaStorageService.create();
  final credentialStore = CredentialStore();
  final oauthService = OAuthService();
  final backendTokenProvider = const SupabaseAccessTokenProvider();
  final backendApiClient = JoblensBackendApiClient(
    baseUrl: configuredApiBaseUrl.isEmpty
        ? '$supabaseUrl/functions/v1/api/v1'
        : configuredApiBaseUrl,
    accessTokenProvider: backendTokenProvider,
  );
  final signedMediaUrlCache = SignedMediaUrlCache();
  final syncService = SyncService(
    database,
    credentialStore,
    oauthService,
    backendApiClient: backendApiClient,
    signedMediaUrlCache: signedMediaUrlCache,
  );
  final store = JoblensStore(
    database: database,
    mediaStorage: mediaStorage,
    syncService: syncService,
    oauthService: oauthService,
  );

  await store.initialize();

  runApp(
    ProviderScope(
      overrides: [
        joblensStoreProvider.overrideWithValue(store),
        availableCamerasProvider.overrideWithValue(cameras),
      ],
      child: const JoblensApp(),
    ),
  );
}
