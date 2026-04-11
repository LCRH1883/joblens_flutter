import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/app_launch_destination.dart';
import 'package:joblens_flutter/src/core/models/provider_account.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('first authenticated session seeds projects as launch destination', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_launch_destination_seed_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final database = await AppDatabase.open(
      databasePath: p.join(tempDir.path, 'joblens.db'),
    );
    final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();

    expect(store.appLaunchDestination, AppLaunchDestination.camera);

    await store.syncAuthSession(_session('user-1'));

    expect(store.appLaunchDestination, AppLaunchDestination.projects);
    expect(
      await database.getStoredAppLaunchDestination(),
      AppLaunchDestination.projects,
    );
  });

  test('launch destination persists across sign out and sign in', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_launch_destination_persist_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final database = await AppDatabase.open(
      databasePath: p.join(tempDir.path, 'joblens.db'),
    );
    final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.setAppLaunchDestination(AppLaunchDestination.camera);

    await store.syncAuthSession(_session('user-1'));
    await store.syncAuthSession(null);
    await store.syncAuthSession(_session('user-2'));

    expect(store.appLaunchDestination, AppLaunchDestination.camera);
    expect(
      await database.getStoredAppLaunchDestination(),
      AppLaunchDestination.camera,
    );
  });

  test('transient null auth session does not clear local sync state', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_auth_transient_null_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final database = await AppDatabase.open(
      databasePath: p.join(tempDir.path, 'joblens.db'),
    );
    final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
    String? currentUserId = 'user-1';
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
      currentAuthUserIdProvider: () => currentUserId,
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await database.updateProviderAccountStatus(
      CloudProviderType.dropbox,
      connectionStatus: ProviderConnectionStatus.ready,
      displayName: 'Dropbox',
      accountIdentifier: 'user-1@example.com',
      isActive: true,
    );
    final projectId = await database.createProject('Library');

    await store.syncAuthSession(null);

    expect(await database.getStoredAuthUserId(), 'user-1');
    expect(await database.getProjectById(projectId), isNotNull);
    final providers = await database.getProviderAccounts();
    final dropbox = providers.firstWhere(
      (provider) => provider.providerType == CloudProviderType.dropbox,
    );
    expect(dropbox.connectionStatus, ProviderConnectionStatus.ready);
  });

  test('explicit sign out clears user data but preserves app launch preference', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_auth_sign_out_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final database = await AppDatabase.open(
      databasePath: p.join(tempDir.path, 'joblens.db'),
    );
    final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
    String? currentUserId = 'user-1';
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
      currentAuthUserIdProvider: () => currentUserId,
      signOutAction: () async {
        currentUserId = null;
      },
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.setAppLaunchDestination(AppLaunchDestination.camera);
    await database.createProject('Library');
    await database.updateProviderAccountStatus(
      CloudProviderType.dropbox,
      connectionStatus: ProviderConnectionStatus.ready,
      displayName: 'Dropbox',
      accountIdentifier: 'user-1@example.com',
      isActive: true,
    );

    await store.signOut();

    expect(await database.getStoredAuthUserId(), isNull);
    expect(
      await database.getStoredAppLaunchDestination(),
      AppLaunchDestination.camera,
    );
    final projects = await database.getProjects();
    expect(projects.map((project) => project.name), ['Inbox']);
    final providers = await database.getProviderAccounts();
    final dropbox = providers.firstWhere(
      (provider) => provider.providerType == CloudProviderType.dropbox,
    );
    expect(
      dropbox.connectionStatus,
      ProviderConnectionStatus.disconnected,
    );
  });
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}

Session _session(String userId) {
  return Session.fromJson({
    'access_token': 'not-a-jwt',
    'token_type': 'bearer',
    'refresh_token': 'refresh-token',
    'expires_in': 3600,
    'user': {
      'id': userId,
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'aud': 'authenticated',
      'email': '$userId@example.com',
      'created_at': DateTime(2026, 4, 11).toIso8601String(),
    },
  })!;
}
