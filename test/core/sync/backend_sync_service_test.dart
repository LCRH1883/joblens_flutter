import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  test('duplicate bulk-check path moves remote asset into destination project', () async {
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

  test('fresh device discovers remote projects and merges cloud assets', () async {
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
        'remote-inbox': const ListAssetsResponse(assets: [], nextCursor: null),
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

    final syncedProjects = await syncService.syncRemoteProjects(initialProjects);
    await syncService.mergeRemoteAssets(syncedProjects);

    final projects = await harness.database.getProjects();
    final inbox = projects.firstWhere((project) => project.name == 'Inbox');
    final library = projects.firstWhere((project) => project.name == 'Library');
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
  });
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
    required this.bulkCheckResponse,
    this.prepareUploadResponse,
    this.commitResponse,
    required this.projectId,
    this.listProjectsResponse,
    this.listAssetsResponses = const {},
    this.downloadBytes = const [1, 2, 3, 4],
  }) : super(
         baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
         accessTokenProvider: const _FakeTokenProvider(),
       );

  final BulkCheckAssetsResponse bulkCheckResponse;
  final PrepareAssetUploadResponse? prepareUploadResponse;
  final CommitAssetResponse? commitResponse;
  final String projectId;
  final ListProjectsResponse? listProjectsResponse;
  final Map<String, ListAssetsResponse> listAssetsResponses;
  final List<int> downloadBytes;

  int uploadCalls = 0;
  int moveCalls = 0;
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
    final result = bulkCheckResponse.results.single;
    return BulkCheckAssetsResponse(
      projectId: projectId,
      duplicateCount: bulkCheckResponse.duplicateCount,
      missingCount: bulkCheckResponse.missingCount,
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
