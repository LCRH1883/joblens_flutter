import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
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

  test('downloadAssetsToDevice skips an asset that already has a local original', () async {
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
  });

  test('downloadMissingProjectAssets repairs assets whose local file is missing', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final projectId = await harness.database.createProject('Library');
    final existingFile = File(p.join(harness.tempDir.path, 'already-local.jpg'));
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

    final result = await harness.store.downloadMissingProjectAssets(projectId);

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
  });

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
      expect(logs.any((log) => log.event == 'archive_blocked_not_synced'), isTrue);
    },
  );

  test('archiveProjectAssets archives eligible assets with partial success', () async {
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
  });
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
  int kickCount = 0;

  @override
  Future<Uint8List> downloadAssetBytes(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId?.trim() ?? '';
    downloadRequests.add(remoteAssetId);
    return _testImageBytes;
  }

  @override
  Future<void> kick({bool forceBootstrap = false}) async {
    kickCount += 1;
  }
}
