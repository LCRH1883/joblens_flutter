import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/sync_job.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('enqueueSyncJob re-queues an existing completed job', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_db_sync_job_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    addTearDown(database.close);

    final projectId = await database.ensureDefaultProject();
    await database.upsertCloudOnlyAsset(
      localAssetId: 'asset-1',
      projectId: projectId,
      remoteAssetId: 'remote-1',
      sha256: 'a' * 64,
      createdAt: DateTime(2026, 4, 8),
    );
    await database.enqueueSyncJob(
      assetId: 'asset-1',
      projectId: projectId,
      provider: CloudProviderType.backend,
    );

    final initialJob = (await database.getSyncJobs()).single;
    await database.updateSyncJob(
      initialJob.copyWith(state: SyncJobState.done, lastError: 'old error'),
    );

    await database.enqueueSyncJob(
      assetId: 'asset-1',
      projectId: projectId + 10,
      provider: CloudProviderType.backend,
    );

    final jobs = await database.getSyncJobs();
    expect(jobs, hasLength(1));
    expect(jobs.single.id, initialJob.id);
    expect(jobs.single.projectId, projectId + 10);
    expect(jobs.single.state, SyncJobState.queued);
    expect(jobs.single.attemptCount, 0);
    expect(jobs.single.lastError, isNull);
  });

  test(
    'updateSyncJob does not overwrite a newer re-queued project id',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_db_sync_job_stale_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      addTearDown(database.close);

      final projectId = await database.ensureDefaultProject();
      await database.upsertCloudOnlyAsset(
        localAssetId: 'asset-1',
        projectId: projectId,
        remoteAssetId: 'remote-1',
        sha256: 'b' * 64,
        createdAt: DateTime(2026, 4, 8),
      );
      await database.enqueueSyncJob(
        assetId: 'asset-1',
        projectId: projectId,
        provider: CloudProviderType.backend,
      );

      final initialJob = (await database.getSyncJobs()).single;
      await database.enqueueSyncJob(
        assetId: 'asset-1',
        projectId: projectId + 99,
        provider: CloudProviderType.backend,
      );

      await database.updateSyncJob(
        initialJob.copyWith(
          state: SyncJobState.done,
          attemptCount: initialJob.attemptCount + 1,
        ),
      );

      final jobs = await database.getSyncJobs();
      expect(jobs, hasLength(1));
      expect(jobs.single.projectId, projectId + 99);
      expect(jobs.single.state, SyncJobState.queued);
      expect(jobs.single.attemptCount, 0);
    },
  );

  test(
    'softDeleteAsset marks asset deleted and clears stale sync jobs',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_db_soft_delete_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      addTearDown(database.close);

      final projectId = await database.ensureDefaultProject();
      await database.upsertCloudOnlyAsset(
        localAssetId: 'asset-1',
        projectId: projectId,
        remoteAssetId: 'remote-1',
        sha256: 'a' * 64,
        createdAt: DateTime(2026, 4, 7),
      );
      await database.enqueueSyncJob(
        assetId: 'asset-1',
        projectId: projectId,
        provider: CloudProviderType.backend,
      );

      await database.softDeleteAsset('asset-1');

      final deletedAsset = await database.getAssetById('asset-1');
      final jobs = await database.getSyncJobs();
      expect(deletedAsset?.status.name, 'deleted');
      expect(deletedAsset?.cloudState, 'deleted');
      expect(jobs, isEmpty);
    },
  );

  test(
    'cleanupSyncState removes stale blob upload for already-synced asset',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_db_cleanup_sync_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      addTearDown(database.close);

      final projectId = await database.ensureDefaultProject();
      await database.upsertCloudOnlyAsset(
        localAssetId: 'asset-1',
        projectId: projectId,
        remoteAssetId: 'remote-1',
        sha256: 'c' * 64,
        createdAt: DateTime(2026, 4, 8),
      );
      await database.upsertBlobUploadTask(
        assetId: 'asset-1',
        uploadGeneration: 1,
        localUri: '/tmp/asset-1.jpg',
      );

      expect(await database.getAllBlobUploadTasks(), isNotEmpty);

      await database.cleanupSyncState();

      expect(await database.getAllBlobUploadTasks(), isEmpty);
    },
  );
}
