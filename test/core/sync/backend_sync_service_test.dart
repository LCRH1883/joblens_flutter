import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/api/api_exception.dart';
import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/api/backend_auth.dart';
import 'package:joblens_flutter/src/core/api/joblens_backend_api_client.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/backend_sync_event.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/entity_sync_record.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/models/provider_account.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'duplicate bulk-check path moves remote asset into destination project',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponse: BulkCheckAssetsResponse(
          projectId: 'remote-project-1',
          duplicateCount: 1,
          missingCount: 0,
          results: [
            BulkCheckResult(
              deviceAssetId: 'asset-local',
              sha256: 'a' * 64,
              status: 'duplicate',
              assetId: 'asset-remote',
            ),
          ],
        ),
        projectId: 'remote-project-1',
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 1);
      await harness.database.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: CloudProviderType.backend,
      );

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(updated?.remoteAssetId, 'asset-remote');
      expect(updated?.cloudState, AssetCloudState.localAndCloud);
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-moved');
      expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
      expect(fakeClient.uploadCalls, 0);
      expect(fakeClient.moveCalls, 1);
      expect(jobs, isEmpty);
    },
  );

  test('successful sync pass updates backend device heartbeat', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(projectId: 'remote-project-1');
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
      mediaStorage: harness.mediaStorage,
    );

    await harness.database.markBootstrapCompleted();
    await syncService.kick(forceBootstrap: false);

    expect(fakeClient.updateDeviceActivityCalls, greaterThanOrEqualTo(1));
    expect(fakeClient.lastUpdatedDeviceId, 'device-backend-1');
    expect(fakeClient.lastUpdatedDeviceLastSyncEventId, 0);
    expect(fakeClient.lastUpdatedDeviceMarkedSyncAt, isTrue);
  });

  test('missing asset path prepares upload, uploads, and commits', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(
      bulkCheckResponse: BulkCheckAssetsResponse(
        projectId: 'remote-project-1',
        duplicateCount: 0,
        missingCount: 1,
        results: [
          BulkCheckResult(
            deviceAssetId: 'asset-local',
            sha256: 'a' * 64,
            status: 'missing',
            assetId: null,
          ),
        ],
      ),
      prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
        'status': 'upload_required',
        'provider': 'google_drive',
        'uploadSessionId': 'session-1',
        'remotePath': 'Joblens/Library/a.jpg',
        'remoteFileId': 'provider-file-1',
        'upload': {
          'strategy': 'single_put',
          'url': 'https://upload.example/file',
          'method': 'PUT',
          'headers': {'x-upload-token': 'abc'},
        },
      }),
      commitResponse: CommitAssetResponse.fromMap({
        'assetId': 'asset-remote-2',
        'duplicate': false,
        'committed': true,
        'provider': 'google_drive',
        'remoteFileId': 'provider-file-1',
        'remotePath': 'Joblens/Library/a.jpg',
      }),
      projectId: 'remote-project-1',
    );
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
    );

    final project = await harness.createProject('Library');
    final asset = await harness.ingestAsset(projectId: project.id, seed: 2);
    await harness.database.enqueueSyncJob(
      assetId: asset.id,
      projectId: asset.projectId,
      provider: CloudProviderType.backend,
    );

    await harness.database.markBootstrapCompleted();
    await syncService.kick(forceBootstrap: false);

    final updated = await harness.database.getAssetById(asset.id);
    final jobs = await harness.database.getSyncJobs();
    expect(fakeClient.uploadCalls, 1);
    expect(fakeClient.lastUploadedBytes, isNotEmpty);
    expect(updated?.remoteAssetId, 'asset-remote-2');
    expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
    expect(updated?.remoteFileId, 'provider-file-1');
    expect(updated?.uploadPath, 'Joblens/Library/a.jpg');
    expect(jobs, isEmpty);
  });

  test(
    'onedrive upload uses final upload response remoteFileId in commit payload',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient =
          _FakeBackendApiClient(
              bulkCheckResponse: BulkCheckAssetsResponse(
                projectId: 'remote-project-1',
                duplicateCount: 0,
                missingCount: 1,
                results: [
                  BulkCheckResult(
                    deviceAssetId: 'asset-local',
                    sha256: 'a' * 64,
                    status: 'missing',
                    assetId: null,
                  ),
                ],
              ),
              prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
                'status': 'upload_required',
                'provider': 'onedrive',
                'uploadSessionId': 'session-onedrive-1',
                'remotePath':
                    'electrical/e45a4a020087_a47eb091-1fcc-41bc-82d6-fc60bcf06e85.jpg',
                'upload': {
                  'strategy': 'chunked_put',
                  'url': 'https://upload.example/onedrive-session',
                  'method': 'PUT',
                  'headers': const {},
                },
              }),
              commitResponse: CommitAssetResponse.fromMap({
                'assetId': 'asset-remote-2',
                'duplicate': false,
                'committed': true,
                'provider': 'onedrive',
                'remoteFileId': 'onedrive-item-42',
                'remotePath':
                    'electrical/e45a4a020087_a47eb091-1fcc-41bc-82d6-fc60bcf06e85.jpg',
              }),
              projectId: 'remote-project-1',
            )
            ..uploadResult = const UploadInstructionResult(
              remoteFileId: 'onedrive-item-42',
              rawResponse: {'id': 'onedrive-item-42'},
            );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
      );

      final project = await harness.createProject('electrical');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 3);
      await harness.database.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: CloudProviderType.backend,
      );

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      expect(
        fakeClient.lastCommitRequest?.provider,
        CloudProviderType.oneDrive,
      );
      expect(fakeClient.lastCommitRequest?.remoteFileId, 'onedrive-item-42');
      expect(
        fakeClient.lastCommitRequest?.uploadSessionId,
        'session-onedrive-1',
      );
    },
  );

  test('placeholder ingest finalization queues and uploads asset', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(
      bulkCheckResponse: BulkCheckAssetsResponse(
        projectId: 'remote-project-1',
        duplicateCount: 0,
        missingCount: 1,
        results: [
          BulkCheckResult(
            deviceAssetId: 'asset-local',
            sha256: 'a' * 64,
            status: 'missing',
            assetId: null,
          ),
        ],
      ),
      prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
        'status': 'upload_required',
        'provider': 'google_drive',
        'uploadSessionId': 'session-placeholder',
        'remotePath': 'Joblens/Library/pending.jpg',
        'remoteFileId': 'provider-file-pending',
        'upload': {
          'strategy': 'single_put',
          'url': 'https://upload.example/file',
          'method': 'PUT',
          'headers': {'x-upload-token': 'abc'},
        },
      }),
      commitResponse: CommitAssetResponse.fromMap({
        'assetId': 'asset-remote-pending',
        'duplicate': false,
        'committed': true,
        'provider': 'google_drive',
        'remoteFileId': 'provider-file-pending',
        'remotePath': 'Joblens/Library/pending.jpg',
      }),
      projectId: 'remote-project-1',
    );
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
      mediaStorage: harness.mediaStorage,
    );

    final project = await harness.createProject('Library');
    final source = File(p.join(harness.tempDir.path, 'pending_asset.jpg'));
    await source.writeAsBytes(List<int>.generate(256, (i) => i % 255));

    final assetId = harness.mediaStorage.createAssetId();
    final shell = PhotoAsset(
      id: assetId,
      localPath: '',
      thumbPath: '',
      createdAt: DateTime(2026, 4, 8),
      importedAt: DateTime(2026, 4, 8),
      projectId: project.id,
      hash: 'pending:$assetId',
      status: AssetStatus.active,
      sourceType: AssetSourceType.imported,
      cloudState: AssetCloudState.localAndCloud,
      existsInPhoneStorage: true,
      ingestState: AssetIngestState.pending,
    );
    await harness.database.insertPendingAssetShell(shell);

    final stored = await harness.mediaStorage.ingestIntoStorage(
      assetId: assetId,
      source: source,
    );
    await harness.database.finalizePendingAssetIngest(
      assetId: assetId,
      localPath: stored.localPath,
      thumbPath: stored.thumbPath,
      hash: stored.hash,
      existsInPhoneStorage: true,
      cloudState: AssetCloudState.localAndCloud,
    );

    await syncService.kick(forceBootstrap: false);

    final updated = await harness.database.getAssetById(assetId);
    final uploads = await harness.database.getAllBlobUploadTasks();
    expect(fakeClient.uploadCalls, 1);
    expect(updated?.remoteAssetId, 'asset-remote-pending');
    expect(updated?.remoteFileId, 'provider-file-pending');
    expect(updated?.uploadPath, 'Joblens/Library/pending.jpg');
    expect(uploads, isEmpty);
  });

  test(
    'active provider backfills existing local-only asset into upload lane',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponse: BulkCheckAssetsResponse(
          projectId: 'remote-project-1',
          duplicateCount: 0,
          missingCount: 1,
          results: [
            BulkCheckResult(
              deviceAssetId: 'asset-local',
              sha256: 'a' * 64,
              status: 'missing',
              assetId: null,
            ),
          ],
        ),
        prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
          'status': 'upload_required',
          'provider': 'dropbox',
          'uploadSessionId': 'session-existing-local',
          'remotePath': 'Joblens/Library/existing.jpg',
          'remoteFileId': 'provider-file-existing',
          'upload': {
            'strategy': 'single_put',
            'url': 'https://upload.example/file',
            'method': 'PUT',
            'headers': {'x-upload-token': 'abc'},
          },
        }),
        commitResponse: CommitAssetResponse.fromMap({
          'assetId': 'asset-remote-existing',
          'duplicate': false,
          'committed': true,
          'provider': 'dropbox',
          'remoteFileId': 'provider-file-existing',
          'remotePath': 'Joblens/Library/existing.jpg',
        }),
        projectId: 'remote-project-1',
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      await harness.database.markProjectSynced(
        project.id,
        remoteProjectId: 'remote-project-1',
        remoteRev: 1,
      );
      await harness.database.updateProviderAccountStatus(
        CloudProviderType.dropbox,
        connectionStatus: ProviderConnectionStatus.ready,
        displayName: 'Dropbox',
        accountIdentifier: 'jane@example.com',
        isActive: true,
      );
      final asset = await harness.ingestAsset(projectId: project.id, seed: 42);
      await harness.database.deleteBlobUploadsForAsset(asset.id);

      expect(await harness.database.getAllBlobUploadTasks(), isEmpty);

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      final updated = await harness.database.getAssetById(asset.id);
      final uploads = await harness.database.getAllBlobUploadTasks();
      expect(fakeClient.uploadCalls, 1);
      expect(updated?.remoteAssetId, 'asset-remote-existing');
      expect(updated?.remoteProvider, CloudProviderType.dropbox.key);
      expect(updated?.remoteFileId, 'provider-file-existing');
      expect(uploads, isEmpty);
    },
  );

  test(
    'sync startup backfills existing local-only project into backend sync',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-existing-project',
        listProjectsResponse: const ListProjectsResponse(projects: []),
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Existing Local Project');
      await harness.database.completeEntitySync(
        SyncEntityType.project,
        project.id.toString(),
      );
      await harness.database.markBootstrapCompleted();

      await syncService.kick(forceBootstrap: false);

      final updated = await harness.database.getProjectById(project.id);
      expect(updated?.remoteProjectId, 'remote-existing-project');
      expect(updated?.remoteRev, 1);
    },
  );

  test('bootstrap failure does not block pending uploads', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(
      bulkCheckResponse: BulkCheckAssetsResponse(
        projectId: 'remote-project-1',
        duplicateCount: 0,
        missingCount: 1,
        results: [
          BulkCheckResult(
            deviceAssetId: 'asset-local',
            sha256: 'a' * 64,
            status: 'missing',
            assetId: null,
          ),
        ],
      ),
      prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
        'status': 'upload_required',
        'provider': 'google_drive',
        'uploadSessionId': 'session-bootstrap-fail',
        'remotePath': 'Joblens/Library/bootstrap-fail.jpg',
        'remoteFileId': 'provider-file-bootstrap-fail',
        'upload': {
          'strategy': 'single_put',
          'url': 'https://upload.example/file',
          'method': 'PUT',
          'headers': {'x-upload-token': 'abc'},
        },
      }),
      commitResponse: CommitAssetResponse.fromMap({
        'assetId': 'asset-remote-bootstrap-fail',
        'duplicate': false,
        'committed': true,
        'provider': 'google_drive',
        'remoteFileId': 'provider-file-bootstrap-fail',
        'remotePath': 'Joblens/Library/bootstrap-fail.jpg',
      }),
      listProjectsError: const ApiException(
        code: 'http_500',
        message: 'bootstrap failed',
        statusCode: 500,
      ),
      projectId: 'remote-project-1',
    );
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
      mediaStorage: harness.mediaStorage,
    );

    final project = await harness.createProject('Library');
    final asset = await harness.ingestAsset(projectId: project.id, seed: 91);

    await syncService.kick(forceBootstrap: true);

    final updated = await harness.database.getAssetById(asset.id);
    expect(fakeClient.listProjectsCalls, greaterThanOrEqualTo(1));
    expect(fakeClient.uploadCalls, 1);
    expect(updated?.remoteAssetId, 'asset-remote-bootstrap-fail');
  });

  test(
    'refreshProviderConnections persists identity and expired state',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-project-1',
        providerConnectionsResponse: ProviderConnectionsResponse(
          connections: [
            ProviderConnectionSummary(
              provider: CloudProviderType.dropbox,
              status: 'expired',
              connectedAt: DateTime.parse('2026-04-08T20:00:00.000Z'),
              lastError: 'token expired',
              displayName: 'Jane Dropbox',
              accountIdentifier: 'jane@example.com',
              syncHealth: 'degraded',
              openConflictCount: 2,
            ),
          ],
        ),
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
      );

      await syncService.refreshProviderConnections();

      final provider = (await harness.database.getProviderAccounts())
          .singleWhere(
            (account) => account.providerType == CloudProviderType.dropbox,
          );
      expect(provider.tokenState, ProviderTokenState.expired);
      expect(provider.displayName, 'Jane Dropbox');
      expect(provider.accountIdentifier, 'jane@example.com');
      expect(provider.connectedAccountLabel, 'Jane Dropbox • jane@example.com');
      expect(provider.syncHealth, 'degraded');
      expect(provider.openConflictCount, 2);
      expect(
        provider.connectedAt?.toUtc().toIso8601String(),
        '2026-04-08T20:00:00.000Z',
      );
    },
  );

  test('reconcileProjects only requests synced projects', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(projectId: 'remote-project-1');
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
    );

    final localOnly = await harness.createProject('Local only');
    final syncedA = await harness.createProject('Synced A');
    final syncedB = await harness.createProject('Synced B');
    await harness.database.markProjectSynced(
      syncedA.id,
      remoteProjectId: 'remote-project-a',
      remoteRev: 1,
    );
    await harness.database.markProjectSynced(
      syncedB.id,
      remoteProjectId: 'remote-project-b',
      remoteRev: 2,
    );
    final projects = await harness.database.getProjects();

    final scheduled = await syncService.reconcileProjects(projects);

    expect(localOnly.remoteProjectId, isNull);
    expect(scheduled, 2);
    expect(fakeClient.reconcileCalls, 2);
    expect(fakeClient.reconciledProjectIds, [
      'remote-project-a',
      'remote-project-b',
    ]);
  });

  test(
    'stale sync snapshot reruns and flushes the updated queued job',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      late int destinationProjectId;
      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponse: BulkCheckAssetsResponse(
          projectId: 'remote-project-1',
          duplicateCount: 0,
          missingCount: 1,
          results: [
            BulkCheckResult(
              deviceAssetId: 'asset-local',
              sha256: 'a' * 64,
              status: 'missing',
              assetId: null,
            ),
          ],
        ),
        prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
          'status': 'upload_required',
          'provider': 'google_drive',
          'uploadSessionId': 'session-stale',
          'remotePath': 'Joblens/Inbox/stale.jpg',
          'remoteFileId': 'provider-file-stale',
          'upload': {
            'strategy': 'single_put',
            'url': 'https://upload.example/file',
            'method': 'PUT',
            'headers': {'x-upload-token': 'abc'},
          },
        }),
        commitResponse: CommitAssetResponse.fromMap({
          'assetId': 'asset-remote-stale',
          'duplicate': false,
          'committed': true,
          'provider': 'google_drive',
          'remoteFileId': 'provider-file-stale',
          'remotePath': 'Joblens/Inbox/stale.jpg',
        }),
        projectId: 'remote-project-1',
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
      );

      final sourceProject = await harness.createProject('Inbox A');
      final destinationProject = await harness.createProject('Inbox B');
      destinationProjectId = destinationProject.id;
      final asset = await harness.ingestAsset(
        projectId: sourceProject.id,
        seed: 42,
      );
      await harness.database.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: CloudProviderType.backend,
      );

      fakeClient.onBulkCheck = () async {
        await harness.database.moveAssetToProject(
          asset.id,
          destinationProjectId,
        );
        await harness.database.enqueueSyncJob(
          assetId: asset.id,
          projectId: destinationProjectId,
          provider: CloudProviderType.backend,
        );
      };

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      final jobs = await harness.database.getSyncJobs();
      final updatedAsset = await harness.database.getAssetById(asset.id);
      expect(fakeClient.uploadCalls, 1);
      expect(updatedAsset?.projectId, destinationProjectId);
      expect(updatedAsset?.remoteAssetId, 'asset-remote-stale');
      expect(jobs, isEmpty);
    },
  );

  test(
    'duplicate commit collision recovers through bulk-check fallback',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponseSequence: [
          BulkCheckAssetsResponse(
            projectId: 'remote-project-1',
            duplicateCount: 0,
            missingCount: 1,
            results: [
              BulkCheckResult(
                deviceAssetId: 'asset-local',
                sha256: 'a' * 64,
                status: 'missing',
                assetId: null,
              ),
            ],
          ),
          BulkCheckAssetsResponse(
            projectId: 'remote-project-1',
            duplicateCount: 1,
            missingCount: 0,
            results: [
              BulkCheckResult(
                deviceAssetId: 'asset-local',
                sha256: 'a' * 64,
                status: 'duplicate',
                assetId: 'asset-remote-duplicate',
              ),
            ],
          ),
        ],
        prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
          'status': 'upload_required',
          'provider': 'google_drive',
          'uploadSessionId': 'session-dup',
          'remotePath': 'Joblens/Library/dup.jpg',
          'remoteFileId': 'provider-file-dup',
          'upload': {
            'strategy': 'single_put',
            'url': 'https://upload.example/file',
            'method': 'PUT',
            'headers': {'x-upload-token': 'abc'},
          },
        }),
        commitException: const ApiException(
          code: 'asset_commit_failed',
          message:
              'duplicate key value violates unique constraint "assets_user_id_sha256_key"',
          statusCode: 400,
        ),
        projectId: 'remote-project-1',
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
      );

      final project = await harness.createProject('Library');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 22);
      await harness.database.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: CloudProviderType.backend,
      );

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(fakeClient.uploadCalls, 1);
      expect(updated?.remoteAssetId, 'asset-remote-duplicate');
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-dup');
      expect(updated?.uploadPath, 'Joblens/Library/dup.jpg');
      expect(jobs, isEmpty);
    },
  );

  test(
    'outer upload failure recovers duplicate collision through bulk-check fallback',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponseSequence: [
          BulkCheckAssetsResponse(
            projectId: 'remote-project-1',
            duplicateCount: 0,
            missingCount: 1,
            results: [
              BulkCheckResult(
                deviceAssetId: 'asset-local',
                sha256: 'a' * 64,
                status: 'missing',
                assetId: null,
              ),
            ],
          ),
          BulkCheckAssetsResponse(
            projectId: 'remote-project-1',
            duplicateCount: 1,
            missingCount: 0,
            results: [
              BulkCheckResult(
                deviceAssetId: 'asset-local',
                sha256: 'a' * 64,
                status: 'duplicate',
                assetId: 'asset-remote-duplicate-outer',
              ),
            ],
          ),
        ],
        prepareUploadResponse: PrepareAssetUploadResponse.fromMap({
          'status': 'upload_required',
          'provider': 'google_drive',
          'uploadSessionId': 'session-dup-outer',
          'remotePath': 'Joblens/Library/dup-outer.jpg',
          'remoteFileId': 'provider-file-dup-outer',
          'upload': {
            'strategy': 'single_put',
            'url': 'https://upload.example/file',
            'method': 'PUT',
            'headers': {'x-upload-token': 'abc'},
          },
        }),
        commitError: Exception(
          'duplicate key value violates unique constraint "assets_user_id_sha256_key"',
        ),
        projectId: 'remote-project-1',
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
      );

      final project = await harness.createProject('Library');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 23);
      await harness.database.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: CloudProviderType.backend,
      );

      await harness.database.markBootstrapCompleted();
      await syncService.kick(forceBootstrap: false);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(fakeClient.uploadCalls, 1);
      expect(updated?.remoteAssetId, 'asset-remote');
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-moved');
      expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
      expect(jobs, isEmpty);
    },
  );

  test('existing remote asset moves directly without re-uploading', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(
      bulkCheckResponse: BulkCheckAssetsResponse(
        projectId: 'remote-project-1',
        duplicateCount: 0,
        missingCount: 1,
        results: [
          BulkCheckResult(
            deviceAssetId: 'asset-local',
            sha256: 'a' * 64,
            status: 'missing',
            assetId: null,
          ),
        ],
      ),
      projectId: 'remote-project-1',
    );
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
    );

    final project = await harness.createProject('Library');
    final asset = await harness.ingestAsset(projectId: project.id, seed: 3);
    await harness.database.updateAssetCloudMetadata(
      assetId: asset.id,
      remoteAssetId: 'asset-remote-existing',
      remoteProvider: CloudProviderType.googleDrive.key,
      remoteFileId: 'provider-file-existing',
      uploadPath: 'Joblens/Inbox/existing.jpg',
      cloudState: AssetCloudState.localAndCloud,
      lastSyncErrorCode: null,
    );
    await harness.database.enqueueSyncJob(
      assetId: asset.id,
      projectId: asset.projectId,
      provider: CloudProviderType.backend,
    );

    await harness.database.markBootstrapCompleted();
    await syncService.kick(forceBootstrap: false);

    final updated = await harness.database.getAssetById(asset.id);
    final jobs = await harness.database.getSyncJobs();
    expect(fakeClient.moveCalls, 1);
    expect(fakeClient.uploadCalls, 0);
    expect(updated?.remoteAssetId, 'asset-remote');
    expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
    expect(updated?.remoteFileId, 'provider-file-moved');
    expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
    expect(jobs, isEmpty);
  });

  test(
    'fresh device discovers remote projects and merges cloud assets',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        bulkCheckResponse: const BulkCheckAssetsResponse(
          projectId: 'unused',
          duplicateCount: 0,
          missingCount: 0,
          results: [],
        ),
        projectId: 'unused',
        listProjectsResponse: const ListProjectsResponse(
          projects: [
            RemoteProjectRecord(projectId: 'remote-inbox', name: 'Inbox'),
            RemoteProjectRecord(projectId: 'remote-library', name: 'Library'),
          ],
        ),
        listAssetsResponses: {
          'remote-inbox': const ListAssetsResponse(
            assets: [],
            nextCursor: null,
          ),
          'remote-library': ListAssetsResponse(
            assets: [
              BackendAssetRecord(
                assetId: 'asset-remote-1',
                sha256: 'b' * 64,
                projectId: 'remote-library',
                filename: 'cloud.jpg',
                createdAt: DateTime(2026, 1, 2),
                provider: CloudProviderType.googleDrive,
                remoteFileId: 'provider-file-1',
                remotePath: 'Joblens/Library/cloud.jpg',
              ),
            ],
            nextCursor: null,
          ),
        },
        downloadBytes: List<int>.generate(256, (index) => index % 255),
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final initialProjects = await harness.database.getProjects();
      expect(initialProjects.single.name, 'Inbox');
      expect(initialProjects.single.remoteProjectId, isNull);

      final syncedProjects = await syncService.syncRemoteProjects(
        initialProjects,
      );
      await syncService.mergeRemoteAssets(syncedProjects);

      final projects = await harness.database.getProjects();
      final inbox = projects.firstWhere((project) => project.name == 'Inbox');
      final library = projects.firstWhere(
        (project) => project.name == 'Library',
      );
      final assets = await harness.database.getAssets(projectId: library.id);

      expect(inbox.remoteProjectId, 'remote-inbox');
      expect(library.remoteProjectId, 'remote-library');
      expect(assets, hasLength(1));
      expect(assets.single.remoteAssetId, 'asset-remote-1');
      expect(assets.single.remoteProvider, CloudProviderType.googleDrive.key);
      expect(assets.single.cloudState, AssetCloudState.localAndCloud);
      expect(assets.single.localPath, isNotEmpty);
      expect(assets.single.thumbPath, isNotEmpty);
      expect(File(assets.single.localPath).existsSync(), isTrue);
      expect(File(assets.single.thumbPath).existsSync(), isTrue);
    },
  );

  test(
    'sync events apply project and asset snapshots without full list refresh',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-library',
        syncEventsResponses: [
          SyncEventsResponse(
            events: [
              BackendSyncEvent(
                id: 1,
                projectId: 'remote-library',
                eventType: 'project_created',
                entityType: 'project',
                entityId: 'remote-library',
                payload: const {
                  'project': {
                    'id': 'remote-library',
                    'projectId': 'remote-library',
                    'name': 'Library',
                    'revision': 2,
                    'deleted': false,
                    'createdAt': '2026-01-01T00:00:00.000Z',
                    'updatedAt': '2026-01-01T00:00:00.000Z',
                  },
                },
                createdAt: DateTime(2026, 1, 1),
              ),
              BackendSyncEvent(
                id: 2,
                projectId: 'remote-library',
                eventType: 'asset_committed',
                entityType: 'asset',
                entityId: 'asset-remote-1',
                payload: const {
                  'asset': {
                    'id': 'asset-remote-1',
                    'assetId': 'asset-remote-1',
                    'projectId': 'remote-library',
                    'sha256':
                        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
                    'mediaType': 'photo',
                    'filename': 'cloud.jpg',
                    'provider': 'google_drive',
                    'remoteFileId': 'provider-file-1',
                    'remotePath': 'Joblens/Library/cloud.jpg',
                    'revision': 4,
                    'deleted': false,
                    'createdAt': '2026-01-02T00:00:00.000Z',
                    'updatedAt': '2026-01-02T00:00:00.000Z',
                  },
                },
                createdAt: DateTime(2026, 1, 2),
              ),
            ],
            nextAfter: 2,
            hasMore: false,
          ),
        ],
        downloadBytes: List<int>.generate(256, (index) => index % 255),
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      await harness.database.setBackendDeviceId('device-backend-1');
      await harness.database.markBootstrapCompleted();

      await syncService.kick();

      expect(fakeClient.listProjectsCalls, 0);
      expect(fakeClient.listAssetsCalls, 0);

      final projects = await harness.database.getProjects();
      final library = projects.firstWhere(
        (project) => project.name == 'Library',
      );
      final assets = await harness.database.getAssets(projectId: library.id);

      expect(library.remoteProjectId, 'remote-library');
      expect(library.remoteRev, 2);
      expect(assets, hasLength(1));
      expect(assets.single.remoteAssetId, 'asset-remote-1');
      expect(assets.single.remoteRev, 4);
      expect(assets.single.localPath, isNotEmpty);
    },
  );

  test(
    'sync events merge remote project into same-name local project',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-electrical',
        syncEventsResponses: [
          SyncEventsResponse(
            events: [
              BackendSyncEvent(
                id: 1,
                projectId: 'remote-electrical',
                eventType: 'project_created',
                entityType: 'project',
                entityId: 'remote-electrical',
                payload: const {
                  'project': {
                    'id': 'remote-electrical',
                    'projectId': 'remote-electrical',
                    'name': 'electrical',
                    'revision': 1,
                    'deleted': false,
                    'createdAt': '2026-04-09T00:00:00.000Z',
                    'updatedAt': '2026-04-09T00:00:00.000Z',
                  },
                },
                createdAt: DateTime(2026, 4, 9),
              ),
            ],
            nextAfter: 1,
            hasMore: false,
          ),
        ],
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final localProjectId = await harness.database.createProject('electrical');
      await harness.database.completeEntitySync(
        SyncEntityType.project,
        localProjectId.toString(),
      );
      await harness.database.markBootstrapCompleted();

      await syncService.kick(forceBootstrap: false);

      final projects = await harness.database.getProjects(includeDeleted: true);
      expect(
        projects.where((project) => project.name == 'electrical'),
        hasLength(1),
      );
      final project = projects.singleWhere((item) => item.id == localProjectId);
      expect(project.remoteProjectId, 'remote-electrical');
      expect(project.remoteRev, 1);
    },
  );

  test(
    'mergeRemoteAssets does not resurrect a locally deleted asset',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-library',
        listAssetsResponses: {
          'remote-library': ListAssetsResponse(
            assets: [
              BackendAssetRecord(
                assetId: 'asset-remote-1',
                sha256: 'c' * 64,
                projectId: 'remote-library',
                filename: 'cloud.jpg',
                createdAt: DateTime(2026, 1, 2),
                provider: CloudProviderType.googleDrive,
                remoteFileId: 'provider-file-1',
                remotePath: 'Joblens/Library/cloud.jpg',
                deleted: false,
              ),
            ],
            nextCursor: null,
          ),
        },
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      await harness.database.updateProjectRemoteId(
        project.id,
        'remote-library',
      );
      final asset = await harness.ingestAsset(projectId: project.id, seed: 88);
      await harness.database.updateAssetCloudMetadata(
        assetId: asset.id,
        remoteAssetId: 'asset-remote-1',
        remoteProvider: CloudProviderType.googleDrive.key,
        remoteFileId: 'provider-file-1',
        uploadPath: 'Joblens/Library/cloud.jpg',
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
      );
      await harness.database.softDeleteAsset(asset.id);

      final syncedProject = await harness.database.getProjectById(project.id);
      await syncService.mergeRemoteAssets([syncedProject!]);

      final updated = await harness.database.getAssetById(asset.id);
      expect(updated?.status, AssetStatus.deleted);
      expect(updated?.cloudState, AssetCloudState.deleted);
    },
  );

  test(
    'mergeRemoteAssets does not bind unrelated same-hash local assets',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-library',
        listAssetsResponses: {
          'remote-library': ListAssetsResponse(
            assets: [
              BackendAssetRecord(
                assetId: 'asset-remote-1',
                sha256: 'd' * 64,
                projectId: 'remote-library',
                filename: 'cloud.jpg',
                createdAt: DateTime(2026, 1, 2),
                provider: CloudProviderType.googleDrive,
                remoteFileId: 'provider-file-1',
                remotePath: 'Joblens/Library/cloud.jpg',
                revision: 3,
              ),
            ],
            nextCursor: null,
          ),
        },
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      await harness.database.updateProjectRemoteId(
        project.id,
        'remote-library',
      );
      final asset = await harness.ingestAsset(
        projectId: project.id,
        seed: 99,
        hashOverride: 'd' * 64,
      );
      final matchedBeforeMerge = await harness.database.getAssetByHash(
        'd' * 64,
      );
      expect(matchedBeforeMerge?.id, asset.id);
      await harness.database.completeBlobUpload(
        asset.id,
        asset.uploadGeneration,
      );

      final syncedProject = await harness.database.getProjectById(project.id);
      await syncService.mergeRemoteAssets([syncedProject!]);

      final blobTasks = await harness.database.getAllBlobUploadTasks();
      expect(blobTasks.where((task) => task.assetId == asset.id), isEmpty);

      final updatedLocal = await harness.database.getAssetById(asset.id);
      expect(updatedLocal?.remoteAssetId, isNull);

      final remoteShadow = await harness.database.getAssetByRemoteId(
        'asset-remote-1',
      );
      expect(remoteShadow, isNotNull);
      expect(remoteShadow?.id, 'remote:asset-remote-1');
      expect(remoteShadow?.remoteRev, 3);
    },
  );

  test('sync kick reconciles stale same-project upload shadows', () async {
    final harness = await _createHarness();
    addTearDown(harness.dispose);

    final fakeClient = _FakeBackendApiClient(projectId: 'remote-library');
    final syncService = SyncService(
      harness.database,
      backendApiClient: fakeClient,
      mediaStorage: harness.mediaStorage,
    );

    final project = await harness.createProject('Library');
    await harness.database.updateProjectRemoteId(project.id, 'remote-library');
    final shadow = await harness.ingestAsset(
      projectId: project.id,
      seed: 111,
      hashOverride: 'e' * 64,
    );
    await harness.database.updateAssetCloudMetadata(
      assetId: shadow.id,
      uploadSessionId: 'upl-shadow-1',
      cloudState: AssetCloudState.localAndCloud,
      lastSyncErrorCode: null,
    );
    await harness.database.applyRemoteAssetSnapshot(
      localAssetId: 'remote:asset-remote-1',
      projectId: project.id,
      remoteAssetId: 'asset-remote-1',
      sha256: 'e' * 64,
      createdAt: DateTime(2026, 1, 2),
      remoteRev: 1,
      filename: 'cloud.jpg',
      remoteProvider: CloudProviderType.googleDrive.key,
      remoteFileId: 'provider-file-1',
      remotePath: 'Joblens/Library/cloud.jpg',
      deleted: false,
    );
    await harness.database.markBootstrapCompleted();

    await syncService.kick(forceBootstrap: false);

    final assets = await harness.database.getAssetsByHashValue('e' * 64);
    expect(assets, hasLength(1));
    expect(assets.single.remoteAssetId, 'asset-remote-1');
    expect(assets.single.localPath.trim(), isNotEmpty);
    expect(assets.single.id, isNot(shadow.id));

    final projectCounts = await harness.database.getProjectCounts();
    expect(projectCounts[project.id], 1);
  });

  test(
    'restore resolves unlinked deleted shadow to canonical remote asset',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(
        projectId: 'remote-library',
        listAssetsResponses: {
          'remote-library': ListAssetsResponse(
            assets: [
              BackendAssetRecord(
                assetId: 'asset-remote-restore-1',
                sha256: 'f' * 64,
                projectId: 'remote-library',
                filename: 'cloud.jpg',
                createdAt: DateTime(2026, 1, 2),
                provider: CloudProviderType.googleDrive,
                remoteFileId: 'provider-file-restore-1',
                remotePath: 'Joblens/Library/cloud.jpg',
                revision: 4,
                deleted: false,
              ),
            ],
            nextCursor: null,
          ),
        },
      );
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      await harness.database.updateProjectRemoteId(
        project.id,
        'remote-library',
      );
      final shadow = await harness.ingestAsset(
        projectId: project.id,
        seed: 112,
        hashOverride: 'f' * 64,
      );
      await harness.database.softDeleteAsset(shadow.id);

      final deletedBefore = await harness.database.getDeletedAssets();
      expect(deletedBefore.map((asset) => asset.id), contains(shadow.id));

      await syncService.restoreAsset(deletedBefore.single);

      final restored = await harness.database.getAssetByRemoteId(
        'asset-remote-restore-1',
      );
      expect(restored, isNotNull);
      expect(restored?.status, AssetStatus.active);
      expect(restored?.deletedAt, isNull);
      expect(restored?.cloudState, AssetCloudState.localOnly);
      expect(restored?.localPath.trim(), isNotEmpty);

      final shadowAfter = await harness.database.getAssetById(shadow.id);
      expect(shadowAfter, isNull);
    },
  );

  test(
    'flushPendingRemoteDeletes retries backend delete for local deletions',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(projectId: 'remote-library');
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 89);
      await harness.database.updateAssetCloudMetadata(
        assetId: asset.id,
        remoteAssetId: 'asset-remote-delete',
        remoteProvider: CloudProviderType.googleDrive.key,
        remoteFileId: 'provider-file-delete',
        uploadPath: 'Joblens/Library/delete.jpg',
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
      );
      await harness.database.softDeleteAsset(asset.id);

      await syncService.flushPendingRemoteDeletes();

      final updated = await harness.database.getAssetById(asset.id);
      expect(fakeClient.deleteCalls, 1);
      expect(fakeClient.deletedAssetIds, contains('asset-remote-delete'));
      expect(updated?.status, AssetStatus.deleted);
      expect(updated?.cloudState, AssetCloudState.deleted);
      expect(updated?.lastSyncErrorCode, isNull);
    },
  );

  test(
    'purgeAsset hides trashed asset immediately while backend purge runs',
    () async {
      final harness = await _createHarness();
      addTearDown(harness.dispose);

      final fakeClient = _FakeBackendApiClient(projectId: 'remote-library');
      final syncService = SyncService(
        harness.database,
        backendApiClient: fakeClient,
        mediaStorage: harness.mediaStorage,
      );

      final project = await harness.createProject('Library');
      final asset = await harness.ingestAsset(projectId: project.id, seed: 144);
      await harness.database.updateAssetCloudMetadata(
        assetId: asset.id,
        remoteAssetId: 'asset-remote-purge',
        remoteProvider: CloudProviderType.googleDrive.key,
        remoteFileId: 'provider-file-purge',
        uploadPath: 'Joblens/Library/purge.jpg',
        cloudState: AssetCloudState.deleted,
        lastSyncErrorCode: null,
      );
      await harness.database.softDeleteAsset(asset.id);

      final deletedBefore = await harness.database.getDeletedAssets();
      expect(deletedBefore.map((item) => item.id), contains(asset.id));

      await syncService.purgeAsset(deletedBefore.single);

      final deletedAfter = await harness.database.getDeletedAssets();
      expect(deletedAfter.map((item) => item.id), isNot(contains(asset.id)));

      final updated = await harness.database.getAssetById(asset.id);
      expect(updated, isNotNull);
      expect(updated?.purgeRequestedAt, isNotNull);
      expect(updated?.status, AssetStatus.deleted);
      expect(fakeClient.purgeCalls, 1);
      expect(fakeClient.purgedAssetIds, contains('asset-remote-purge'));
    },
  );
}

class _Harness {
  _Harness({
    required this.tempDir,
    required this.database,
    required this.mediaStorage,
  });

  final Directory tempDir;
  final AppDatabase database;
  final MediaStorageService mediaStorage;

  Future<Project> createProject(String name) async {
    final id = await database.createProject(name);
    return (await database.getProjects()).firstWhere((item) => item.id == id);
  }

  Future<PhotoAsset> ingestAsset({
    required int projectId,
    required int seed,
    String? hashOverride,
  }) async {
    final source = File(p.join(tempDir.path, 'asset_$seed.jpg'));
    await source.writeAsBytes(List<int>.generate(256, (i) => (i + seed) % 255));
    final asset = await mediaStorage.ingestFile(
      source: source,
      sourceType: AssetSourceType.captured,
      projectId: projectId,
    );
    await database.upsertAsset(asset);
    if (hashOverride != null) {
      await database.updateAssetLocalMedia(
        assetId: asset.id,
        localPath: asset.localPath,
        thumbPath: asset.thumbPath,
        hash: hashOverride,
        cloudState: asset.cloudState,
      );
    }
    return (await database.getAssetById(asset.id))!;
  }

  Future<void> dispose() async {
    await database.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

Future<_Harness> _createHarness() async {
  final tempDir = await Directory.systemTemp.createTemp('joblens_sync_test_');
  final dbPath = p.join(tempDir.path, 'joblens.db');
  final database = await AppDatabase.open(databasePath: dbPath);
  final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
  await database.ensureDefaultProject();
  await database.ensureProviderRows();
  return _Harness(
    tempDir: tempDir,
    database: database,
    mediaStorage: mediaStorage,
  );
}

class _FakeBackendApiClient extends JoblensBackendApiClient {
  _FakeBackendApiClient({
    this.bulkCheckResponse = const BulkCheckAssetsResponse(
      projectId: 'unused',
      duplicateCount: 0,
      missingCount: 0,
      results: [],
    ),
    this.bulkCheckResponseSequence,
    this.prepareUploadResponse,
    this.commitResponse,
    this.commitException,
    this.commitError,
    this.listProjectsError,
    required this.projectId,
    this.listProjectsResponse,
    this.listAssetsResponses = const {},
    this.syncEventsResponses = const [],
    this.providerConnectionsResponse = const ProviderConnectionsResponse(
      connections: [],
    ),
    this.downloadBytes = const [1, 2, 3, 4],
  }) : super(
         baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
         accessTokenProvider: const _FakeTokenProvider(),
       );

  final BulkCheckAssetsResponse bulkCheckResponse;
  final List<BulkCheckAssetsResponse>? bulkCheckResponseSequence;
  final PrepareAssetUploadResponse? prepareUploadResponse;
  final CommitAssetResponse? commitResponse;
  final ApiException? commitException;
  final Object? commitError;
  final ApiException? listProjectsError;
  final String projectId;
  final ListProjectsResponse? listProjectsResponse;
  final Map<String, ListAssetsResponse> listAssetsResponses;
  final List<SyncEventsResponse> syncEventsResponses;
  final ProviderConnectionsResponse providerConnectionsResponse;
  final List<int> downloadBytes;
  Future<void> Function()? onBulkCheck;

  int uploadCalls = 0;
  int moveCalls = 0;
  int bulkCheckCalls = 0;
  int deleteCalls = 0;
  int purgeCalls = 0;
  int restoreCalls = 0;
  int listProjectsCalls = 0;
  int listAssetsCalls = 0;
  int syncEventsCalls = 0;
  int reconcileCalls = 0;
  int updateDeviceActivityCalls = 0;
  List<int> lastUploadedBytes = const [];
  UploadInstructionResult uploadResult = const UploadInstructionResult();
  String? lastUpdatedDeviceId;
  int? lastUpdatedDeviceLastSyncEventId;
  bool lastUpdatedDeviceMarkedSyncAt = false;
  CommitAssetRequest? lastCommitRequest;
  final List<String> deletedAssetIds = <String>[];
  final List<String> purgedAssetIds = <String>[];
  final List<String> restoredAssetIds = <String>[];
  final List<String> reconciledProjectIds = <String>[];

  @override
  Future<RemoteProjectRecord> upsertProject(
    RemoteProjectUpsertRequest request,
  ) async {
    return RemoteProjectRecord(
      projectId: projectId,
      name: request.name,
      revision: 1,
    );
  }

  @override
  Future<RegisterDeviceResponse> registerDevice({
    required String clientDeviceId,
    required String platform,
    String? appVersion,
    String? deviceName,
    String? osVersion,
  }) async {
    return const RegisterDeviceResponse(
      deviceId: 'device-backend-1',
      isCurrent: true,
      deviceSessionId: 'device-session-1',
    );
  }

  @override
  Future<SyncEventsResponse> getSyncEvents({
    required int after,
    int limit = 200,
  }) async {
    syncEventsCalls += 1;
    if (syncEventsResponses.isEmpty) {
      return SyncEventsResponse(
        events: const [],
        nextAfter: after,
        hasMore: false,
      );
    }
    final index = syncEventsCalls - 1;
    if (index < syncEventsResponses.length) {
      return syncEventsResponses[index];
    }
    return SyncEventsResponse(
      events: const [],
      nextAfter: after,
      hasMore: false,
    );
  }

  @override
  Future<void> ackSyncEvents({
    required String deviceId,
    required int upToEventId,
  }) async {}

  @override
  Future<void> updateDeviceActivity({
    required String deviceId,
    int? lastSyncEventId,
    bool markSyncAt = false,
  }) async {
    updateDeviceActivityCalls += 1;
    lastUpdatedDeviceId = deviceId;
    lastUpdatedDeviceLastSyncEventId = lastSyncEventId;
    lastUpdatedDeviceMarkedSyncAt = markSyncAt;
  }

  @override
  Future<ListProjectsResponse> listProjects() async {
    listProjectsCalls += 1;
    if (listProjectsError != null) {
      throw listProjectsError!;
    }
    return listProjectsResponse ?? const ListProjectsResponse(projects: []);
  }

  @override
  Future<ProviderConnectionsResponse> listProviderConnections() async {
    return providerConnectionsResponse;
  }

  @override
  Future<void> reconcileProject(String remoteProjectId) async {
    reconcileCalls += 1;
    reconciledProjectIds.add(remoteProjectId);
  }

  @override
  Future<ListAssetsResponse> listAssets(ListAssetsRequest request) async {
    listAssetsCalls += 1;
    return listAssetsResponses[request.projectId] ??
        const ListAssetsResponse(assets: [], nextCursor: null);
  }

  @override
  Future<Uint8List> downloadAssetBytes(String assetId) async {
    return Uint8List.fromList(downloadBytes);
  }

  @override
  Future<BulkCheckAssetsResponse> bulkCheckAssets({
    required String projectId,
    required List<BulkCheckAssetInput> assets,
  }) async {
    if (onBulkCheck != null) {
      await onBulkCheck!();
      onBulkCheck = null;
    }
    final source =
        bulkCheckResponseSequence != null &&
            bulkCheckCalls < bulkCheckResponseSequence!.length
        ? bulkCheckResponseSequence![bulkCheckCalls]
        : bulkCheckResponse;
    bulkCheckCalls += 1;
    final result = source.results.single;
    return BulkCheckAssetsResponse(
      projectId: projectId,
      duplicateCount: source.duplicateCount,
      missingCount: source.missingCount,
      results: [
        BulkCheckResult(
          deviceAssetId: assets.single.deviceAssetId,
          sha256: assets.single.sha256,
          status: result.status,
          assetId: result.assetId,
        ),
      ],
    );
  }

  @override
  Future<PrepareAssetUploadResponse> prepareAssetUpload(
    PrepareAssetUploadRequest request,
  ) async {
    return prepareUploadResponse!;
  }

  @override
  Future<UploadInstructionResult> uploadWithInstruction({
    required DirectUploadInstruction instruction,
    required Uint8List bytes,
    required String contentType,
    required String filename,
  }) async {
    uploadCalls += 1;
    lastUploadedBytes = List<int>.from(bytes);
    return uploadResult;
  }

  @override
  Future<CommitAssetResponse> commitAsset(CommitAssetRequest request) async {
    lastCommitRequest = request;
    if (commitError != null) {
      throw commitError!;
    }
    if (commitException != null) {
      throw commitException!;
    }
    return commitResponse!;
  }

  @override
  Future<MoveAssetResponse> moveAssetToProject({
    required String assetId,
    required String projectId,
    int? expectedRevision,
  }) async {
    moveCalls += 1;
    return const MoveAssetResponse(
      assetId: 'asset-remote',
      projectId: 'remote-project-1',
      provider: CloudProviderType.googleDrive,
      remoteFileId: 'provider-file-moved',
      remotePath: 'Joblens/Library/asset-local.jpg',
      revision: null,
    );
  }

  @override
  Future<void> deleteAsset(String assetId, {int? expectedRevision}) async {
    deleteCalls += 1;
    deletedAssetIds.add(assetId);
  }

  @override
  Future<void> purgeAsset(String assetId, {int? expectedRevision}) async {
    purgeCalls += 1;
    purgedAssetIds.add(assetId);
  }

  @override
  Future<BackendAssetRecord> restoreAsset(
    String assetId, {
    int? expectedRevision,
  }) async {
    restoreCalls += 1;
    restoredAssetIds.add(assetId);
    final match = listAssetsResponses.values
        .expand((response) => response.assets)
        .firstWhere((asset) => asset.assetId == assetId);
    return BackendAssetRecord(
      assetId: match.assetId,
      sha256: match.sha256,
      projectId: match.projectId,
      filename: match.filename,
      createdAt: match.createdAt,
      takenAt: match.takenAt,
      revision: match.revision,
      provider: match.provider,
      remoteFileId: match.remoteFileId,
      remotePath: match.remotePath,
      storageState: AssetCloudState.localOnly,
      deleted: false,
      softDeletedAt: null,
      hardDeleteDueAt: null,
    );
  }
}

class _FakeTokenProvider implements AccessTokenProvider {
  const _FakeTokenProvider();

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => 'token';
}
