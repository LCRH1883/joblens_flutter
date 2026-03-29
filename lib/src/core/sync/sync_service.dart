import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../api/api_exception.dart';
import '../api/backend_api_models.dart';
import '../api/joblens_backend_api_client.dart';
import '../api/signed_media_url_cache.dart';
import '../db/app_database.dart';
import '../models/cloud_provider.dart';
import '../models/photo_asset.dart';
import '../models/project.dart';
import '../models/provider_account.dart';
import '../models/sync_job.dart';
import 'cloud_adapter.dart';

class SyncService {
  SyncService(
    this._db, {
    JoblensBackendApiClient? backendApiClient,
    SignedMediaUrlCache? signedMediaUrlCache,
  }) : _backendApiClient = backendApiClient,
       _signedMediaUrlCache = signedMediaUrlCache ?? SignedMediaUrlCache();

  final AppDatabase _db;
  final JoblensBackendApiClient? _backendApiClient;
  final SignedMediaUrlCache _signedMediaUrlCache;
  bool _isRunning = false;

  Future<void> enqueueAsset(PhotoAsset asset) async {
    await _db.enqueueSyncJob(
      assetId: asset.id,
      projectId: asset.projectId,
      provider: CloudProviderType.backend,
    );
  }

  Future<void> enqueueAssets(Iterable<PhotoAsset> assets) async {
    for (final asset in assets) {
      await enqueueAsset(asset);
    }
  }

  Future<void> enqueueProjectBackfill(
    Project project,
    List<PhotoAsset> assets,
  ) async {
    for (final asset in assets.where((item) => item.projectId == project.id)) {
      await _db.enqueueSyncJob(
        assetId: asset.id,
        projectId: project.id,
        provider: CloudProviderType.backend,
      );
    }
  }

  Future<void> pauseProvider(CloudProviderType provider) async {
    if (provider != CloudProviderType.backend) {
      await _db.updateProviderAccountStatus(
        provider,
        ProviderTokenState.disconnected,
      );
      return;
    }

    final jobs = await _db.getSyncJobs();
    for (final job in jobs.where(
      (item) =>
          item.providerType == provider &&
          (item.state == SyncJobState.queued ||
              item.state == SyncJobState.failed),
    )) {
      await _db.updateSyncJob(job.copyWith(state: SyncJobState.paused));
    }
  }

  Future<void> resumeProvider(CloudProviderType provider) async {
    if (provider != CloudProviderType.backend) {
      return;
    }

    final jobs = await _db.getSyncJobs();
    for (final job in jobs.where(
      (item) =>
          item.providerType == provider && item.state == SyncJobState.paused,
    )) {
      await _db.updateSyncJob(
        job.copyWith(state: SyncJobState.queued, lastError: null),
      );
    }
  }

  Future<void> retryFailed() async {
    await _db.setAllFailedToQueued();
  }

  Future<void> refreshProviderConnections() async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    final response = await client.listProviderConnections();
    for (final connection in response.connections) {
      final state = switch (connection.status) {
        'connected' => ProviderTokenState.connected,
        'expired' => ProviderTokenState.expired,
        _ => ProviderTokenState.disconnected,
      };
      await _db.updateProviderAccountStatus(
        connection.provider,
        state,
        connectedAt: connection.connectedAt,
      );
    }
  }

  Future<String> beginProviderConnection(CloudProviderType provider) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    if (provider == CloudProviderType.nextcloud ||
        provider == CloudProviderType.backend) {
      throw CloudSyncException(
        '${provider.label} does not use browser-based OAuth.',
      );
    }
    final response = await client.beginProviderConnection(provider);
    return response.authorizationUrl;
  }

  Future<void> connectNextcloud({
    required String serverUrl,
    required String username,
    required String appPassword,
  }) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    await client.connectNextcloud(
      NextcloudConnectionRequest(
        serverUrl: serverUrl,
        username: username,
        appPassword: appPassword,
      ),
    );
    await refreshProviderConnections();
  }

  Future<void> disconnectProvider(CloudProviderType provider) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    if (provider == CloudProviderType.backend) {
      return;
    }
    await client.disconnectProvider(provider);
    await _db.updateProviderAccountStatus(
      provider,
      ProviderTokenState.disconnected,
    );
  }

  Future<String?> syncProject(Project project) async {
    final client = _backendApiClient;
    if (client == null) {
      return project.remoteProjectId;
    }

    final response = await client.upsertProject(
      RemoteProjectUpsertRequest(
        localProjectId: project.id,
        name: project.name,
        remoteProjectId: project.remoteProjectId,
      ),
    );
    await _db.updateProjectRemoteId(project.id, response.projectId);
    return response.projectId;
  }

  Future<void> archiveProject(String remoteProjectId) async {
    final client = _backendApiClient;
    if (client == null || remoteProjectId.isEmpty) {
      return;
    }
    await client.archiveProject(remoteProjectId);
  }

  Future<void> processQueue(List<Project> projects) async {
    if (_isRunning) {
      return;
    }

    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    _isRunning = true;
    try {
      await _db.recoverInterruptedSyncJobs();
      final pending = await _db.getPendingSyncJobs();
      if (pending.isEmpty) {
        return;
      }

      final jobsByAssetId = <String, List<SyncJob>>{};
      for (final job in pending) {
        if (job.state == SyncJobState.paused) {
          continue;
        }
        jobsByAssetId.putIfAbsent(job.assetId, () => []).add(job);
      }
      if (jobsByAssetId.isEmpty) {
        return;
      }

      final assets = await _db.getAssetsByIds(jobsByAssetId.keys);
      final assetsById = {for (final asset in assets) asset.id: asset};
      final projectsById = {
        for (final project in projects) project.id: project,
      };

      final groupedByRemoteProject = <String, List<_PendingAssetContext>>{};
      for (final entry in jobsByAssetId.entries) {
        final jobs = entry.value;
        final asset = assetsById[entry.key];
        if (asset == null) {
          await _markJobsFailed(
            jobs,
            errorCode: 'asset_missing',
            errorMessage: 'Asset no longer exists locally.',
          );
          continue;
        }

        final project = projectsById[asset.projectId];
        if (project == null) {
          await _db.updateAssetSyncError(asset.id, 'project_missing');
          await _markJobsFailed(
            jobs,
            errorCode: 'project_missing',
            errorMessage: 'Project no longer exists locally.',
          );
          continue;
        }

        String remoteProjectId;
        try {
          remoteProjectId = (await syncProject(project))?.trim() ?? '';
        } catch (error) {
          final mapped = _mapSyncError(error);
          await _db.updateAssetSyncError(asset.id, mapped.code);
          await _markJobsFailed(
            jobs,
            errorCode: mapped.code,
            errorMessage: mapped.message,
          );
          continue;
        }

        if (remoteProjectId.isEmpty) {
          await _db.updateAssetSyncError(asset.id, 'project_sync_failed');
          await _markJobsFailed(
            jobs,
            errorCode: 'project_sync_failed',
            errorMessage: 'Unable to create or resolve backend project.',
          );
          continue;
        }

        await _markJobsUploading(jobs);
        groupedByRemoteProject
            .putIfAbsent(remoteProjectId, () => [])
            .add(_PendingAssetContext(asset: asset, jobs: jobs));
      }

      for (final groupEntry in groupedByRemoteProject.entries) {
        final remoteProjectId = groupEntry.key;
        final contexts = groupEntry.value;
        final batchChunks = _chunk(contexts, 500);

        for (final chunk in batchChunks) {
          BulkCheckAssetsResponse response;
          try {
            response = await client.bulkCheckAssets(
              projectId: remoteProjectId,
              assets: chunk
                  .map(
                    (item) => BulkCheckAssetInput(
                      deviceAssetId: item.asset.id,
                      sha256: item.asset.hash,
                    ),
                  )
                  .toList(growable: false),
            );
          } catch (error) {
            final mapped = _mapSyncError(error);
            for (final item in chunk) {
              await _db.updateAssetSyncError(item.asset.id, mapped.code);
              await _markJobsFailed(
                item.jobs,
                errorCode: mapped.code,
                errorMessage: mapped.message,
              );
            }
            continue;
          }

          final resultsByDevice = {
            for (final result in response.results) result.deviceAssetId: result,
          };

          for (final item in chunk) {
            final result = resultsByDevice[item.asset.id];
            if (result == null) {
              await _db.updateAssetSyncError(
                item.asset.id,
                'bulk_check_missing_result',
              );
              await _markJobsFailed(
                item.jobs,
                errorCode: 'bulk_check_missing_result',
                errorMessage:
                    'Backend did not return bulk-check result for this asset.',
              );
              continue;
            }

            if (result.isDuplicate) {
              await _handleDuplicate(
                item,
                result.assetId,
                remoteProjectId: remoteProjectId,
              );
              continue;
            }

            await _handleMissingAssetUpload(
              item,
              remoteProjectId: remoteProjectId,
            );
          }
        }
      }
    } finally {
      _isRunning = false;
    }
  }

  Future<void> mergeRemoteAssets(List<Project> projects) async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    final mappedProjects = {
      for (final project in projects)
        if (project.remoteProjectId != null &&
            project.remoteProjectId!.isNotEmpty)
          project.remoteProjectId!: project.id,
    };
    if (mappedProjects.isEmpty) {
      return;
    }

    for (final entry in mappedProjects.entries) {
      final remoteProjectId = entry.key;
      final fallbackLocalProjectId = entry.value;

      var cursor = '';
      do {
        final response = await client.listAssets(
          ListAssetsRequest(
            cursor: cursor.isEmpty ? null : cursor,
            limit: 200,
            projectId: remoteProjectId,
            includeDeleted: true,
          ),
        );

        for (final remoteAsset in response.assets) {
          await _mergeRemoteAsset(
            remoteAsset,
            fallbackLocalProjectId: fallbackLocalProjectId,
          );
        }

        cursor = response.nextCursor ?? '';
      } while (cursor.isNotEmpty);
    }
  }

  Future<String?> getThumbnailUrl(
    PhotoAsset asset, {
    bool forceRefresh = false,
  }) async {
    final remoteAssetId = asset.remoteAssetId;
    final client = _backendApiClient;
    if (client == null || remoteAssetId == null || remoteAssetId.isEmpty) {
      return null;
    }

    return _signedMediaUrlCache.resolve(
      assetId: remoteAssetId,
      kind: SignedMediaUrlKind.thumbnail,
      forceRefresh: forceRefresh,
      loader: () => client.getThumbnailUrl(remoteAssetId),
    );
  }

  Future<String?> getDownloadUrl(
    PhotoAsset asset, {
    bool forceRefresh = false,
  }) async {
    final remoteAssetId = asset.remoteAssetId;
    final client = _backendApiClient;
    if (client == null || remoteAssetId == null || remoteAssetId.isEmpty) {
      return null;
    }

    return _signedMediaUrlCache.resolve(
      assetId: remoteAssetId,
      kind: SignedMediaUrlKind.download,
      forceRefresh: forceRefresh,
      loader: () => client.getDownloadUrl(remoteAssetId),
    );
  }

  Future<String?> getVideoPreviewUrl(
    PhotoAsset asset, {
    bool forceRefresh = false,
  }) async {
    final remoteAssetId = asset.remoteAssetId;
    final client = _backendApiClient;
    if (client == null || remoteAssetId == null || remoteAssetId.isEmpty) {
      return null;
    }

    return _signedMediaUrlCache.resolve(
      assetId: remoteAssetId,
      kind: SignedMediaUrlKind.videoPreview,
      forceRefresh: forceRefresh,
      loader: () => client.getVideoPreviewUrl(remoteAssetId),
    );
  }

  Future<void> invalidateThumbnailUrl(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId;
    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      return;
    }
    _signedMediaUrlCache.invalidate(
      remoteAssetId,
      SignedMediaUrlKind.thumbnail,
    );
  }

  Future<void> invalidateDownloadUrl(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId;
    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      return;
    }
    _signedMediaUrlCache.invalidate(remoteAssetId, SignedMediaUrlKind.download);
  }

  Future<void> _mergeRemoteAsset(
    BackendAssetRecord remoteAsset, {
    required int fallbackLocalProjectId,
  }) async {
    final localProjectId = remoteAsset.projectId == null
        ? fallbackLocalProjectId
        : await _db.getLocalProjectIdByRemoteId(remoteAsset.projectId!) ??
              fallbackLocalProjectId;

    final existingByRemote = await _db.getAssetByRemoteId(remoteAsset.assetId);
    final existingByHash =
        existingByRemote ?? await _db.getAssetByHash(remoteAsset.sha256);

    if (existingByHash != null) {
      final cloudState = remoteAsset.deleted
          ? AssetCloudState.deleted
          : existingByHash.localPath.isEmpty
          ? AssetCloudState.cloudOnly
          : AssetCloudState.localAndCloud;
      await _db.upsertAsset(
        existingByHash.copyWith(
          projectId: localProjectId,
          status: remoteAsset.deleted
              ? AssetStatus.deleted
              : AssetStatus.active,
          cloudState: cloudState,
          remoteAssetId: remoteAsset.assetId,
          remoteProvider: remoteAsset.provider?.key,
          remoteFileId: remoteAsset.remoteFileId,
          uploadPath: remoteAsset.remotePath,
          lastSyncErrorCode: null,
        ),
      );
      await _db.updateAssetCloudMetadata(
        assetId: existingByHash.id,
        remoteAssetId: remoteAsset.assetId,
        remoteProvider: remoteAsset.provider?.key,
        remoteFileId: remoteAsset.remoteFileId,
        uploadPath: remoteAsset.remotePath,
        cloudState: cloudState,
        lastSyncErrorCode: null,
      );
      return;
    }

    await _db.upsertCloudOnlyAsset(
      localAssetId: 'remote:${remoteAsset.assetId}',
      projectId: localProjectId,
      remoteAssetId: remoteAsset.assetId,
      remoteProvider: remoteAsset.provider?.key,
      remoteFileId: remoteAsset.remoteFileId,
      remotePath: remoteAsset.remotePath,
      sha256: remoteAsset.sha256,
      createdAt: remoteAsset.takenAt ?? remoteAsset.createdAt ?? DateTime.now(),
      deleted: remoteAsset.deleted,
    );
  }

  Future<void> _handleDuplicate(
    _PendingAssetContext context,
    String? remoteAssetId, {
    required String remoteProjectId,
  }) async {
    final client = _backendApiClient;
    if (client != null && remoteAssetId != null && remoteAssetId.isNotEmpty) {
      final moved = await client.moveAssetToProject(
        assetId: remoteAssetId,
        projectId: remoteProjectId,
      );
      await _db.updateAssetCloudMetadata(
        assetId: context.asset.id,
        remoteAssetId: moved.assetId,
        remoteProvider: moved.provider?.key,
        remoteFileId: moved.remoteFileId,
        uploadPath: moved.remotePath,
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
      );
      await _db.updateAssetSyncError(context.asset.id, null);
      await _markJobsDone(context.jobs);
      return;
    }

    await _db.updateAssetCloudMetadata(
      assetId: context.asset.id,
      remoteAssetId: remoteAssetId,
      cloudState: AssetCloudState.localAndCloud,
      lastSyncErrorCode: null,
    );
    await _db.updateAssetSyncError(context.asset.id, null);
    await _markJobsDone(context.jobs);
  }

  Future<void> _handleMissingAssetUpload(
    _PendingAssetContext context, {
    required String remoteProjectId,
  }) async {
    try {
      final outcome = await _uploadAndCommitWithRetry(
        context,
        remoteProjectId: remoteProjectId,
      );
      await _db.updateAssetCloudMetadata(
        assetId: context.asset.id,
        remoteAssetId: outcome.remoteAssetId,
        remoteProvider: outcome.remoteProvider?.key,
        remoteFileId: outcome.remoteFileId,
        uploadSessionId: outcome.uploadSessionId,
        uploadPath: outcome.remotePath,
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
      );
      await _db.updateAssetSyncError(context.asset.id, null);
      await _markJobsDone(context.jobs);
    } catch (error) {
      final mapped = _mapSyncError(error);
      await _db.updateAssetSyncError(context.asset.id, mapped.code);
      await _markJobsFailed(
        context.jobs,
        errorCode: mapped.code,
        errorMessage: mapped.message,
      );
    }
  }

  Future<_UploadOutcome> _uploadAndCommitWithRetry(
    _PendingAssetContext context, {
    required String remoteProjectId,
  }) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const ApiException(
        code: 'backend_unavailable',
        message: 'Backend API client is not configured.',
      );
    }

    final file = File(context.asset.localPath);
    if (!await file.exists()) {
      throw ApiException(
        code: 'file_missing',
        message: 'Local file does not exist: ${context.asset.localPath}',
      );
    }

    final bytes = await file.readAsBytes();
    final mimeType = lookupMimeType(context.asset.localPath) ?? 'image/jpeg';
    final filename = p.basename(context.asset.localPath);

    var retriedMissingObject = false;
    var retriedSessionMismatch = false;
    String? uploadSessionHint = context.asset.uploadSessionId;

    while (true) {
      final prepared = await client.prepareAssetUpload(
        PrepareAssetUploadRequest(
          projectId: remoteProjectId,
          sha256: context.asset.hash,
          mediaType: 'photo',
          bytes: bytes.length,
          filename: filename,
          mimeType: mimeType,
          deviceAssetId: context.asset.id,
          takenAt: context.asset.createdAt,
          uploadSessionId: uploadSessionHint,
        ),
      );

      if (prepared.isDuplicate) {
        return _UploadOutcome(
          remoteAssetId: prepared.assetId ?? '',
          remoteProvider: prepared.provider,
          remoteFileId: prepared.remoteFileId,
          uploadSessionId: prepared.uploadSessionId,
          remotePath: prepared.remotePath,
        );
      }

      final instruction = prepared.instruction;
      final remotePath = prepared.remotePath;
      if (!prepared.isUploadRequired ||
          instruction == null ||
          remotePath == null ||
          remotePath.isEmpty) {
        throw const ApiException(
          code: 'invalid_prepare_upload_response',
          message:
              'Prepare-upload response is missing upload instructions or remote path.',
        );
      }

      await client.uploadWithInstruction(
        instruction: instruction,
        bytes: bytes,
        contentType: mimeType,
        filename: filename,
      );

      try {
        final commit = await client.commitAsset(
          CommitAssetRequest(
            projectId: remoteProjectId,
            sha256: context.asset.hash,
            mediaType: 'photo',
            filename: filename,
            mimeType: mimeType,
            bytes: bytes.length,
            durationMs: 0,
            takenAt: context.asset.createdAt,
            deviceAssetId: context.asset.id,
            uploadSessionId: prepared.uploadSessionId,
            provider: prepared.provider,
            remoteFileId: prepared.remoteFileId,
            remotePath: remotePath,
          ),
        );

        final remoteAssetId = commit.assetId;
        if (remoteAssetId == null || remoteAssetId.isEmpty) {
          throw const ApiException(
            code: 'invalid_commit_response',
            message: 'Commit response did not include an asset id.',
          );
        }

        return _UploadOutcome(
          remoteAssetId: remoteAssetId,
          remoteProvider: commit.provider ?? prepared.provider,
          remoteFileId: commit.remoteFileId ?? prepared.remoteFileId,
          uploadSessionId: prepared.uploadSessionId,
          remotePath: commit.remotePath ?? remotePath,
        );
      } on ApiException catch (error) {
        if (error.code == 'uploaded_object_not_found' &&
            !retriedMissingObject) {
          retriedMissingObject = true;
          uploadSessionHint = null;
          continue;
        }
        if (error.code == 'idempotency_key_reuse_mismatch' &&
            !retriedSessionMismatch) {
          retriedSessionMismatch = true;
          uploadSessionHint = null;
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _markJobsUploading(List<SyncJob> jobs) async {
    for (final job in jobs) {
      await _db.updateSyncJob(
        job.copyWith(state: SyncJobState.uploading, lastError: null),
      );
    }
  }

  Future<void> _markJobsDone(List<SyncJob> jobs) async {
    for (final job in jobs) {
      await _db.updateSyncJob(
        job.copyWith(
          state: SyncJobState.done,
          attemptCount: job.attemptCount + 1,
          lastError: null,
        ),
      );
    }
  }

  Future<void> _markJobsFailed(
    List<SyncJob> jobs, {
    required String errorCode,
    required String errorMessage,
  }) async {
    for (final job in jobs) {
      await _db.updateSyncJob(
        job.copyWith(
          state: SyncJobState.failed,
          attemptCount: job.attemptCount + 1,
          lastError: '[$errorCode] $errorMessage',
        ),
      );
    }
  }

  _MappedSyncError _mapSyncError(Object error) {
    if (error is ApiException) {
      return _MappedSyncError(code: error.code, message: error.message);
    }
    if (error is CloudSyncException) {
      return _MappedSyncError(code: 'provider_error', message: error.message);
    }
    return _MappedSyncError(code: 'network_error', message: error.toString());
  }
}

class _PendingAssetContext {
  const _PendingAssetContext({required this.asset, required this.jobs});

  final PhotoAsset asset;
  final List<SyncJob> jobs;
}

class _UploadOutcome {
  const _UploadOutcome({
    required this.remoteAssetId,
    required this.remoteProvider,
    required this.remoteFileId,
    required this.uploadSessionId,
    required this.remotePath,
  });

  final String remoteAssetId;
  final CloudProviderType? remoteProvider;
  final String? remoteFileId;
  final String? uploadSessionId;
  final String? remotePath;
}

class _MappedSyncError {
  const _MappedSyncError({required this.code, required this.message});

  final String code;
  final String message;
}

List<List<T>> _chunk<T>(List<T> items, int chunkSize) {
  if (items.isEmpty) {
    return const [];
  }
  final chunks = <List<T>>[];
  for (var index = 0; index < items.length; index += chunkSize) {
    final end = (index + chunkSize < items.length)
        ? index + chunkSize
        : items.length;
    chunks.add(items.sublist(index, end));
  }
  return chunks;
}
