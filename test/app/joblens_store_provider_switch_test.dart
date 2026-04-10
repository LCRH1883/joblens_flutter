import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/provider_account.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'asset synced through a different provider shows as syncing after provider switch',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_switch_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: _ProviderSwitchSyncService(database),
      );
      addTearDown(store.dispose);
      addTearDown(database.close);

      final projectId = await database.ensureDefaultProject();
      await database.ensureProviderRows();
      await database.updateProviderAccountStatus(
        CloudProviderType.dropbox,
        connectionStatus: ProviderConnectionStatus.ready,
        displayName: 'Dropbox',
        accountIdentifier: 'jane@example.com',
        isActive: true,
      );
      await database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-1',
          localPath: '/tmp/asset-1.jpg',
          thumbPath: '/tmp/asset-1-thumb.jpg',
          createdAt: DateTime(2026, 4, 8),
          importedAt: DateTime(2026, 4, 8),
          projectId: projectId,
          hash: 'a' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: true,
          remoteAssetId: 'remote-asset-1',
          remoteProvider: CloudProviderType.oneDrive.key,
          remoteFileId: 'provider-file-1',
          uploadPath: 'Joblens/Inbox/asset-1.jpg',
        ),
      );

      await store.initialize();

      expect(store.assetSyncStatusFor('asset-1'), AssetSyncStatus.syncing);
    },
  );

  test(
    'provider connection backfill schedules project reconcile before sync kick',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_backfill_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
      final syncService = _ProviderSwitchSyncService(database);
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
      );
      addTearDown(store.dispose);
      addTearDown(database.close);

      await database.ensureDefaultProject();
      await database.ensureProviderRows();
      final syncedProjectId = await database.createProject('Library');
      await database.markProjectSynced(
        syncedProjectId,
        remoteProjectId: 'remote-project-1',
        remoteRev: 1,
      );

      syncService.onRefreshProviderConnections = () async {
        await database.updateProviderAccountStatus(
          CloudProviderType.dropbox,
          connectionStatus: ProviderConnectionStatus.ready,
          displayName: 'Dropbox',
          accountIdentifier: 'jane@example.com',
          isActive: true,
        );
      };

      await store.initialize();
      await store.backfillCloudSyncAfterProviderConnection();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(syncService.reconcileCalls, 1);
      expect(syncService.lastReconciledProjectIds, ['remote-project-1']);
      expect(syncService.kickCalls, 1);
      expect(syncService.lastKickForceBootstrap, isTrue);
    },
  );

  test('disconnected provider does not expose stale account identity', () async {
    final account = ProviderAccount(
      id: 'dropbox',
      providerType: CloudProviderType.dropbox,
      displayName: 'Jane Dropbox',
      accountIdentifier: 'jane@example.com',
      connectionStatus: ProviderConnectionStatus.disconnected,
      connectedAt: DateTime(2026, 4, 10),
      isActive: false,
    );

    expect(account.hasActiveConnection, isFalse);
    expect(account.connectedAccountLabel, isNull);
  });
}

class _ProviderSwitchSyncService extends SyncService {
  _ProviderSwitchSyncService(super.db) : super();

  Future<void> Function()? onRefreshProviderConnections;
  int reconcileCalls = 0;
  int kickCalls = 0;
  bool lastKickForceBootstrap = false;
  List<String> lastReconciledProjectIds = const [];

  @override
  Future<void> refreshProviderConnections() async {
    if (onRefreshProviderConnections != null) {
      await onRefreshProviderConnections!();
    }
  }

  @override
  Future<void> retryFailed() async {}

  @override
  Future<int> reconcileProjects(Iterable<Project> projects) async {
    reconcileCalls += 1;
    lastReconciledProjectIds = projects
        .map((project) => project.remoteProjectId)
        .whereType<String>()
        .toList(growable: false);
    return lastReconciledProjectIds.length;
  }

  @override
  Future<void> kick({bool forceBootstrap = false}) async {
    kickCalls += 1;
    lastKickForceBootstrap = forceBootstrap;
  }
}
