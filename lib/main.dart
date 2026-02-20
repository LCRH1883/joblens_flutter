import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app.dart';
import 'src/app/joblens_store.dart';
import 'src/core/db/app_database.dart';
import 'src/core/storage/media_storage_service.dart';
import 'src/core/sync/credential_store.dart';
import 'src/core/sync/oauth/oauth_service.dart';
import 'src/core/sync/sync_service.dart';
import 'src/features/camera/camera_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final syncService = SyncService(database, credentialStore, oauthService);
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
