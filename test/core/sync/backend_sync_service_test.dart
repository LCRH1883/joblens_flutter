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
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/models/sync_job.dart';
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

      await syncService.processQueue([project]);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(updated?.remoteAssetId, 'asset-remote');
      expect(updated?.cloudState, AssetCloudState.localAndCloud);
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-moved');
      expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
      expect(fakeClient.uploadCalls, 0);
      expect(fakeClient.moveCalls, 1);
      expect(jobs.single.state, SyncJobState.done);
    },
  );

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

    await syncService.processQueue([project]);

    final updated = await harness.database.getAssetById(asset.id);
    final jobs = await harness.database.getSyncJobs();
    expect(fakeClient.uploadCalls, 1);
    expect(fakeClient.lastUploadedBytes, isNotEmpty);
    expect(updated?.remoteAssetId, 'asset-remote-2');
    expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
    expect(updated?.remoteFileId, 'provider-file-1');
    expect(updated?.uploadPath, 'Joblens/Library/a.jpg');
    expect(jobs.single.state, SyncJobState.done);
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

      await syncService.processQueue([sourceProject, destinationProject]);

      final jobs = await harness.database.getSyncJobs();
      final updatedAsset = await harness.database.getAssetById(asset.id);
      expect(fakeClient.uploadCalls, 1);
      expect(updatedAsset?.projectId, destinationProjectId);
      expect(updatedAsset?.remoteAssetId, 'asset-remote-stale');
      expect(jobs.single.projectId, destinationProjectId);
      expect(jobs.single.state, SyncJobState.done);
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

      await syncService.processQueue([project]);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(fakeClient.uploadCalls, 1);
      expect(updated?.remoteAssetId, 'asset-remote-duplicate');
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-dup');
      expect(updated?.uploadPath, 'Joblens/Library/dup.jpg');
      expect(jobs.single.state, SyncJobState.done);
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

      await syncService.processQueue([project]);

      final updated = await harness.database.getAssetById(asset.id);
      final jobs = await harness.database.getSyncJobs();
      expect(fakeClient.uploadCalls, 1);
      expect(updated?.remoteAssetId, 'asset-remote');
      expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
      expect(updated?.remoteFileId, 'provider-file-moved');
      expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
      expect(jobs.single.state, SyncJobState.done);
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

    await syncService.processQueue([project]);

    final updated = await harness.database.getAssetById(asset.id);
    final jobs = await harness.database.getSyncJobs();
    expect(fakeClient.moveCalls, 1);
    expect(fakeClient.uploadCalls, 0);
    expect(updated?.remoteAssetId, 'asset-remote');
    expect(updated?.remoteProvider, CloudProviderType.googleDrive.key);
    expect(updated?.remoteFileId, 'provider-file-moved');
    expect(updated?.uploadPath, 'Joblens/Library/asset-local.jpg');
    expect(jobs.single.state, SyncJobState.done);
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
  }) async {
    final source = File(p.join(tempDir.path, 'asset_$seed.jpg'));
    await source.writeAsBytes(List<int>.generate(256, (i) => (i + seed) % 255));
    final asset = await mediaStorage.ingestFile(
      source: source,
      sourceType: AssetSourceType.captured,
      projectId: projectId,
    );
    await database.upsertAsset(asset);
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
    required this.projectId,
    this.listProjectsResponse,
    this.listAssetsResponses = const {},
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
  final String projectId;
  final ListProjectsResponse? listProjectsResponse;
  final Map<String, ListAssetsResponse> listAssetsResponses;
  final List<int> downloadBytes;
  Future<void> Function()? onBulkCheck;

  int uploadCalls = 0;
  int moveCalls = 0;
  int bulkCheckCalls = 0;
  List<int> lastUploadedBytes = const [];

  @override
  Future<RemoteProjectRecord> upsertProject(
    RemoteProjectUpsertRequest request,
  ) async {
    return RemoteProjectRecord(projectId: projectId, name: request.name);
  }

  @override
  Future<ListProjectsResponse> listProjects() async {
    return listProjectsResponse ?? const ListProjectsResponse(projects: []);
  }

  @override
  Future<ListAssetsResponse> listAssets(ListAssetsRequest request) async {
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
  Future<void> uploadWithInstruction({
    required DirectUploadInstruction instruction,
    required Uint8List bytes,
    required String contentType,
    required String filename,
  }) async {
    uploadCalls += 1;
    lastUploadedBytes = List<int>.from(bytes);
  }

  @override
  Future<CommitAssetResponse> commitAsset(CommitAssetRequest request) async {
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
  }) async {
    moveCalls += 1;
    return const MoveAssetResponse(
      assetId: 'asset-remote',
      projectId: 'remote-project-1',
      provider: CloudProviderType.googleDrive,
      remoteFileId: 'provider-file-moved',
      remotePath: 'Joblens/Library/asset-local.jpg',
    );
  }
}

class _FakeTokenProvider implements AccessTokenProvider {
  const _FakeTokenProvider();

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => 'token';
}
