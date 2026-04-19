import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/api/api_exception.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/provider_account.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'downloadAssetsToDevice stores a cloud-only asset locally without enqueuing uploads',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-1',
        projectId: projectId,
        remoteAssetId: 'remote-1',
        sha256: 'a' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/asset-1.jpg',
      );
      await harness.store.refresh();

      final result = await harness.store.downloadAssetsToDevice(
        harness.store.assets.where((asset) => asset.id == 'asset-1'),
      );

      expect(result.downloadedCount, 1);
      expect(result.skippedCount, 0);
      expect(result.failedCount, 0);
      expect(harness.syncService.downloadRequests, ['remote-1']);

      final updated = await harness.database.getAssetById('asset-1');
      expect(updated, isNotNull);
      expect(updated!.cloudState, AssetCloudState.localAndCloud);
      expect(updated.localPath, isNotEmpty);
      expect(File(updated.localPath).existsSync(), isTrue);
      expect(await harness.database.getAllBlobUploadTasks(), isEmpty);

      final logs = await harness.database.getAllSyncLogs();
      expect(logs.any((log) => log.event == 'download_started'), isTrue);
      expect(logs.any((log) => log.event == 'download_completed'), isTrue);
    },
  );

  test(
    'downloaded asset stays synced when the active provider mirror is marked failed',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.googleDrive,
        connectionStatus: ProviderConnectionStatus.ready,
        connectionId: 'conn-1',
        connectedAt: DateTime(2026, 4, 14),
        isActive: true,
      );
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-failed-mirror',
        projectId: projectId,
        remoteAssetId: 'remote-failed-mirror',
        remoteProvider: CloudProviderType.googleDrive.key,
        remoteFileId: 'provider-file-failed-mirror',
        remotePath: 'Joblens/Inbox/failed-mirror.jpg',
        sha256: '0' * 64,
        createdAt: DateTime(2026, 4, 14),
      );
      await harness.database.upsertAssetProviderMirror(
        assetId: 'asset-failed-mirror',
        providerConnectionId: 'conn-1',
        status: 'failed',
        lastError: 'needs_client_upload',
      );
      await harness.store.refresh();

      final result = await harness.store.downloadAssetsToDevice(
        harness.store.assets.where(
          (asset) => asset.id == 'asset-failed-mirror',
        ),
      );

      expect(result.downloadedCount, 1);
      expect(result.skippedCount, 0);
      expect(result.failedCount, 0);

      final updated = await harness.database.getAssetById(
        'asset-failed-mirror',
      );
      expect(updated, isNotNull);
      expect(updated!.cloudState, AssetCloudState.localAndCloud);
      expect(updated.localPath, isNotEmpty);
      expect(
        harness.store.assetSyncStatusFor('asset-failed-mirror'),
        AssetSyncStatus.synced,
      );
    },
  );

  test(
    'download cloud-unavailable failure forces a remote refresh instead of creating a permanent failed badge',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-unavailable',
        projectId: projectId,
        remoteAssetId: 'remote-unavailable',
        remoteProvider: CloudProviderType.googleDrive.key,
        remoteFileId: 'provider-file-unavailable',
        remotePath: 'Joblens/Inbox/unavailable.jpg',
        sha256: '9' * 64,
        createdAt: DateTime(2026, 4, 14),
      );
      harness.syncService.downloadErrorsByRemoteAssetId['remote-unavailable'] =
          const ApiException(
            code: 'asset_cloud_unavailable',
            message: 'Asset is no longer available from the provider.',
          );
      await harness.store.refresh();

      final result = await harness.store.downloadAssetsToDevice(
        harness.store.assets.where((asset) => asset.id == 'asset-unavailable'),
      );

      expect(result.downloadedCount, 0);
      expect(result.failedCount, 1);
      expect(harness.syncService.kickCount, 1);
      expect(
        harness.store.assetSyncStatusFor('asset-unavailable'),
        AssetSyncStatus.cloudOnly,
      );
    },
  );

  test(
    'downloadAssetsToDevice skips an asset that already has a local original',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      final existingFile = File(p.join(harness.tempDir.path, 'existing.jpg'));
      await existingFile.writeAsBytes(_testImageBytes, flush: true);
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-1',
          localPath: existingFile.path,
          thumbPath: existingFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'b' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-1',
          remoteProvider: 'google_drive',
          remoteFileId: 'provider-file-1',
          uploadPath: 'Joblens/Inbox/existing.jpg',
        ),
      );
      await harness.store.refresh();

      final result = await harness.store.downloadAssetsToDevice(
        harness.store.assets.where((asset) => asset.id == 'asset-1'),
      );

      expect(result.downloadedCount, 0);
      expect(result.skippedCount, 1);
      expect(result.failedCount, 0);
      expect(harness.syncService.downloadRequests, isEmpty);

      final logs = await harness.database.getAllSyncLogs();
      expect(
        logs.any((log) => log.event == 'download_skipped_already_local'),
        isTrue,
      );
    },
  );

  test(
    'downloadMissingProjectAssets repairs assets whose local file is missing',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.createProject('Library');
      final existingFile = File(
        p.join(harness.tempDir.path, 'already-local.jpg'),
      );
      await existingFile.writeAsBytes(_testImageBytes, flush: true);

      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-missing',
          localPath: p.join(harness.tempDir.path, 'missing.jpg'),
          thumbPath: '',
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'c' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-missing',
          remoteProvider: 'google_drive',
          remoteFileId: 'provider-file-2',
          uploadPath: 'Joblens/Library/missing.jpg',
        ),
      );
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-local',
          localPath: existingFile.path,
          thumbPath: existingFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'd' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-local',
          remoteProvider: 'google_drive',
          remoteFileId: 'provider-file-3',
          uploadPath: 'Joblens/Library/already-local.jpg',
        ),
      );
      await harness.store.refresh();

      final result = await harness.store.downloadMissingProjectAssets(
        projectId,
      );

      expect(result.downloadedCount, 1);
      expect(result.skippedCount, 1);
      expect(result.failedCount, 0);
      expect(harness.syncService.downloadRequests, ['remote-missing']);

      final repaired = await harness.database.getAssetById('asset-missing');
      expect(repaired, isNotNull);
      expect(repaired!.localPath, isNotEmpty);
      expect(File(repaired.localPath).existsSync(), isTrue);
      expect(repaired.cloudState, AssetCloudState.localAndCloud);
      expect(await harness.database.getAllBlobUploadTasks(), isEmpty);
    },
  );

  test(
    'ensurePersistentThumbnail stores a cloud-only thumbnail without changing local media state',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb',
        projectId: projectId,
        remoteAssetId: 'remote-thumb',
        sha256: '4' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb.jpg',
      );
      await harness.store.refresh();

      final asset = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb',
      );
      final thumbPath = await harness.store.ensurePersistentThumbnail(asset);

      expect(thumbPath, isNotNull);
      expect(thumbPath, isNotEmpty);
      expect(File(thumbPath!).existsSync(), isTrue);
      expect(harness.syncService.thumbnailRequests, ['remote-thumb']);

      final updated = await harness.database.getAssetById('asset-thumb');
      expect(updated, isNotNull);
      expect(updated!.localPath, isEmpty);
      expect(updated.thumbPath, thumbPath);
      expect(updated.cloudState, AssetCloudState.cloudOnly);
    },
  );

  test(
    'ensurePersistentThumbnail deduplicates concurrent cloud-only thumbnail downloads',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb-concurrent',
        projectId: projectId,
        remoteAssetId: 'remote-thumb-concurrent',
        sha256: '5' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb-concurrent.jpg',
      );
      await harness.store.refresh();

      final asset = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb-concurrent',
      );
      final gate = Completer<void>();
      harness.syncService.thumbnailGate = gate;

      final first = harness.store.ensurePersistentThumbnail(asset);
      final second = harness.store.ensurePersistentThumbnail(asset);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(harness.syncService.thumbnailRequests, [
        'remote-thumb-concurrent',
      ]);

      gate.complete();
      final results = await Future.wait([first, second]);

      expect(results[0], isNotNull);
      expect(results[0], results[1]);
      expect(harness.syncService.thumbnailRequests, [
        'remote-thumb-concurrent',
      ]);
    },
  );

  test(
    'ensurePersistentThumbnail hydrates different cloud-only assets one at a time',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb-queue-a',
        projectId: projectId,
        remoteAssetId: 'remote-thumb-queue-a',
        sha256: '8' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb-queue-a.jpg',
      );
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb-queue-b',
        projectId: projectId,
        remoteAssetId: 'remote-thumb-queue-b',
        sha256: '9' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb-queue-b.jpg',
      );
      await harness.store.refresh();

      final assetA = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb-queue-a',
      );
      final assetB = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb-queue-b',
      );
      final gateA = Completer<void>();
      harness
              .syncService
              .thumbnailGatesByRemoteAssetId['remote-thumb-queue-a'] =
          gateA;

      final first = harness.store.ensurePersistentThumbnail(assetA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final second = harness.store.ensurePersistentThumbnail(assetB);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(harness.syncService.thumbnailRequests, ['remote-thumb-queue-a']);

      gateA.complete();
      final results = await Future.wait([first, second]);

      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(harness.syncService.thumbnailRequests, [
        'remote-thumb-queue-a',
        'remote-thumb-queue-b',
      ]);
      expect(harness.syncService.maxConcurrentThumbnailDownloads, 1);
    },
  );

  test(
    'ensurePersistentThumbnail repairs a missing persisted thumbnail file',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb-repair',
        projectId: projectId,
        remoteAssetId: 'remote-thumb-repair',
        sha256: '6' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb-repair.jpg',
      );
      await harness.store.refresh();

      final asset = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb-repair',
      );
      final firstPath = await harness.store.ensurePersistentThumbnail(asset);
      expect(firstPath, isNotNull);
      await File(firstPath!).delete();

      final repairedPath = await harness.store.ensurePersistentThumbnail(asset);

      expect(repairedPath, firstPath);
      expect(File(repairedPath!).existsSync(), isTrue);
      expect(harness.syncService.thumbnailRequests, [
        'remote-thumb-repair',
        'remote-thumb-repair',
      ]);
    },
  );

  test(
    'ensurePersistentThumbnail reuses an existing local thumbnail while offline',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-thumb-offline',
        projectId: projectId,
        remoteAssetId: 'remote-thumb-offline',
        sha256: '7' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/thumb-offline.jpg',
      );
      await harness.store.refresh();

      final asset = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-thumb-offline',
      );
      final thumbPath = await harness.store.ensurePersistentThumbnail(asset);
      expect(thumbPath, isNotNull);

      harness
              .syncService
              .thumbnailErrorsByRemoteAssetId['remote-thumb-offline'] =
          const ApiException(
            code: 'thumbnail_download_unavailable',
            message: 'Offline',
          );

      final reusedPath = await harness.store.ensurePersistentThumbnail(asset);

      expect(reusedPath, thumbPath);
      expect(harness.syncService.thumbnailRequests, ['remote-thumb-offline']);
    },
  );

  test(
    'archiveAssetsToCloudOnly archives a synced asset and preserves a standalone thumbnail',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.googleDrive,
        connectionStatus: ProviderConnectionStatus.ready,
        connectionId: 'conn-1',
        connectedAt: DateTime(2026, 4, 14),
        isActive: true,
      );

      final originalFile = File(p.join(harness.tempDir.path, 'archive-me.jpg'));
      await originalFile.writeAsBytes(_testImageBytes, flush: true);
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-archive',
          localPath: originalFile.path,
          thumbPath: originalFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'e' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-archive',
          remoteProvider: CloudProviderType.googleDrive.key,
          remoteFileId: 'provider-file-archive',
          uploadPath: 'Joblens/Inbox/archive-me.jpg',
        ),
      );
      await harness.database.upsertAssetProviderMirror(
        assetId: 'asset-archive',
        providerConnectionId: 'conn-1',
        status: 'mirrored',
      );
      await harness.store.refresh();

      final result = await harness.store.archiveAssetsToCloudOnly(
        harness.store.assets.where((asset) => asset.id == 'asset-archive'),
      );

      expect(result.archivedCount, 1);
      expect(result.skippedCount, 0);
      expect(result.failedCount, 0);

      final updated = await harness.database.getAssetById('asset-archive');
      expect(updated, isNotNull);
      expect(updated!.cloudState, AssetCloudState.cloudOnly);
      expect(updated.localPath, isEmpty);
      expect(updated.thumbPath, isNotEmpty);
      expect(updated.thumbPath, isNot(originalFile.path));
      expect(File(updated.thumbPath).existsSync(), isTrue);
      expect(originalFile.existsSync(), isFalse);
      expect(await harness.database.getAllBlobUploadTasks(), isEmpty);

      final logs = await harness.database.getAllSyncLogs();
      expect(logs.any((log) => log.event == 'archive_started'), isTrue);
      expect(logs.any((log) => log.event == 'archive_completed'), isTrue);
    },
  );

  test(
    'archive then download keeps an imported asset local_and_cloud and synced',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.googleDrive,
        connectionStatus: ProviderConnectionStatus.ready,
        connectionId: 'conn-1',
        connectedAt: DateTime(2026, 4, 14),
        isActive: true,
      );

      final originalFile = File(p.join(harness.tempDir.path, 'imported.jpg'));
      await originalFile.writeAsBytes(_testImageBytes, flush: true);
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-imported',
          localPath: originalFile.path,
          thumbPath: originalFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'f' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-imported',
          remoteProvider: CloudProviderType.googleDrive.key,
          remoteFileId: 'provider-file-imported',
          uploadPath: 'Joblens/Inbox/imported.jpg',
        ),
      );
      await harness.database.upsertAssetProviderMirror(
        assetId: 'asset-imported',
        providerConnectionId: 'conn-1',
        status: 'mirrored',
      );
      await harness.store.refresh();

      final archiveResult = await harness.store.archiveAssetsToCloudOnly(
        harness.store.assets.where((asset) => asset.id == 'asset-imported'),
      );
      expect(archiveResult.archivedCount, 1);

      final downloadResult = await harness.store.downloadAssetsToDevice(
        harness.store.assets.where((asset) => asset.id == 'asset-imported'),
      );

      expect(downloadResult.downloadedCount, 1);
      expect(downloadResult.skippedCount, 0);
      expect(downloadResult.failedCount, 0);

      final updated = await harness.database.getAssetById('asset-imported');
      expect(updated, isNotNull);
      expect(updated!.cloudState, AssetCloudState.localAndCloud);
      expect(updated.localPath, isNotEmpty);
      expect(File(updated.localPath).existsSync(), isTrue);
      expect(
        harness.store.assetSyncStatusFor('asset-imported'),
        AssetSyncStatus.synced,
      );
    },
  );

  test(
    'archiveAssetsToCloudOnly blocks an asset that is not confirmed on the active provider',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.ensureDefaultProject();
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.googleDrive,
        connectionStatus: ProviderConnectionStatus.ready,
        connectionId: 'conn-1',
        connectedAt: DateTime(2026, 4, 14),
        isActive: true,
      );

      final originalFile = File(p.join(harness.tempDir.path, 'not-synced.jpg'));
      await originalFile.writeAsBytes(_testImageBytes, flush: true);
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-not-synced',
          localPath: originalFile.path,
          thumbPath: originalFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: 'f' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-not-synced',
          remoteProvider: CloudProviderType.box.key,
          remoteFileId: 'provider-file-not-synced',
          uploadPath: 'Joblens/Inbox/not-synced.jpg',
        ),
      );
      await harness.store.refresh();

      final result = await harness.store.archiveAssetsToCloudOnly(
        harness.store.assets.where((asset) => asset.id == 'asset-not-synced'),
      );

      expect(harness.syncService.kickCount, 1);
      expect(result.archivedCount, 0);
      expect(result.skippedCount, 0);
      expect(result.failedCount, 1);

      final updated = await harness.database.getAssetById('asset-not-synced');
      expect(updated, isNotNull);
      expect(updated!.cloudState, AssetCloudState.localAndCloud);
      expect(updated.localPath, originalFile.path);
      expect(originalFile.existsSync(), isTrue);

      final logs = await harness.database.getAllSyncLogs();
      expect(
        logs.any((log) => log.event == 'archive_blocked_not_synced'),
        isTrue,
      );
    },
  );

  test(
    'archiveProjectAssets archives eligible assets with partial success',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final projectId = await harness.database.createProject('Archive Project');
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.googleDrive,
        connectionStatus: ProviderConnectionStatus.ready,
        connectionId: 'conn-1',
        connectedAt: DateTime(2026, 4, 14),
        isActive: true,
      );

      final safeFile = File(p.join(harness.tempDir.path, 'safe.jpg'));
      final blockedFile = File(p.join(harness.tempDir.path, 'blocked.jpg'));
      await safeFile.writeAsBytes(_testImageBytes, flush: true);
      await blockedFile.writeAsBytes(_testImageBytes, flush: true);

      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-safe',
          localPath: safeFile.path,
          thumbPath: safeFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: '1' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-safe',
          remoteProvider: CloudProviderType.googleDrive.key,
          remoteFileId: 'provider-file-safe',
          uploadPath: 'Joblens/Archive/safe.jpg',
        ),
      );
      await harness.database.upsertAssetProviderMirror(
        assetId: 'asset-safe',
        providerConnectionId: 'conn-1',
        status: 'mirrored',
      );
      await harness.database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-blocked',
          localPath: blockedFile.path,
          thumbPath: blockedFile.path,
          createdAt: DateTime(2026, 4, 14),
          importedAt: DateTime(2026, 4, 14),
          projectId: projectId,
          hash: '2' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: false,
          remoteAssetId: 'remote-blocked',
          remoteProvider: CloudProviderType.box.key,
          remoteFileId: 'provider-file-blocked',
          uploadPath: 'Joblens/Archive/blocked.jpg',
        ),
      );
      await harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-cloud-only',
        projectId: projectId,
        remoteAssetId: 'remote-cloud-only',
        sha256: '3' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Archive/cloud-only.jpg',
      );
      await harness.store.refresh();

      final result = await harness.store.archiveProjectAssets(projectId);

      expect(result.archivedCount, 1);
      expect(result.skippedCount, 1);
      expect(result.failedCount, 1);

      final archived = await harness.database.getAssetById('asset-safe');
      final blocked = await harness.database.getAssetById('asset-blocked');
      final cloudOnly = await harness.database.getAssetById('asset-cloud-only');
      expect(archived!.cloudState, AssetCloudState.cloudOnly);
      expect(blocked!.cloudState, AssetCloudState.localAndCloud);
      expect(cloudOnly!.cloudState, AssetCloudState.cloudOnly);
    },
  );
}

final Uint8List _testImageBytes = Uint8List.fromList(
  img.encodeJpg(img.Image(width: 8, height: 8)),
);

Future<_StoreHarness> _createHarness() async {
  final tempDir = await Directory.systemTemp.createTemp(
    'joblens_store_download_test_',
  );
  final dbPath = p.join(tempDir.path, 'joblens.db');
  final database = await AppDatabase.open(databasePath: dbPath);
  final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
  final syncService = _DownloadSyncService(database);
  final store = JoblensStore(
    database: database,
    mediaStorage: mediaStorage,
    syncService: syncService,
  );
  await store.initialize();
  return _StoreHarness(
    store: store,
    database: database,
    tempDir: tempDir,
    syncService: syncService,
  );
}

class _StoreHarness {
  _StoreHarness({
    required this.store,
    required this.database,
    required this.tempDir,
    required this.syncService,
  });

  final JoblensStore store;
  final AppDatabase database;
  final Directory tempDir;
  final _DownloadSyncService syncService;

  Future<void> dispose() async {
    await store.waitForIdle();
    store.dispose();
    await database.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

class _DownloadSyncService extends SyncService {
  _DownloadSyncService(super.db) : super();

  final List<String> downloadRequests = <String>[];
  final List<String> thumbnailRequests = <String>[];
  final Map<String, Object> downloadErrorsByRemoteAssetId = <String, Object>{};
  final Map<String, Object> thumbnailErrorsByRemoteAssetId = <String, Object>{};
  final Map<String, Completer<void>> thumbnailGatesByRemoteAssetId =
      <String, Completer<void>>{};
  Completer<void>? thumbnailGate;
  int kickCount = 0;
  int _activeThumbnailDownloads = 0;
  int maxConcurrentThumbnailDownloads = 0;

  @override
  Future<Uint8List> downloadAssetBytes(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId?.trim() ?? '';
    downloadRequests.add(remoteAssetId);
    final configuredError = downloadErrorsByRemoteAssetId[remoteAssetId];
    if (configuredError != null) {
      throw configuredError;
    }
    return _testImageBytes;
  }

  @override
  Future<Uint8List> downloadThumbnailBytes(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId?.trim() ?? '';
    thumbnailRequests.add(remoteAssetId);
    _activeThumbnailDownloads += 1;
    if (_activeThumbnailDownloads > maxConcurrentThumbnailDownloads) {
      maxConcurrentThumbnailDownloads = _activeThumbnailDownloads;
    }
    try {
      final gate =
          thumbnailGatesByRemoteAssetId[remoteAssetId] ?? thumbnailGate;
      if (gate != null && !gate.isCompleted) {
        await gate.future;
      }
      final configuredError = thumbnailErrorsByRemoteAssetId[remoteAssetId];
      if (configuredError != null) {
        throw configuredError;
      }
      return _testImageBytes;
    } finally {
      _activeThumbnailDownloads -= 1;
    }
  }

  @override
  Future<void> kick({bool forceBootstrap = false}) async {
    kickCount += 1;
  }
}
