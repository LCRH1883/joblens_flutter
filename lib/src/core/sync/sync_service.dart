import 'dart:io';
import 'package:flutter/foundation.dart';
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
import '../models/sync_log_entry.dart';
import '../models/sync_job.dart';
import '../storage/media_storage_service.dart';
import 'cloud_adapter.dart';

class SyncService {
  SyncService(
    this._db, {
    JoblensBackendApiClient? backendApiClient,
    SignedMediaUrlCache? signedMediaUrlCache,
    MediaStorageService? mediaStorage,
  }) : _backendApiClient = backendApiClient,
       _signedMediaUrlCache = signedMediaUrlCache ?? SignedMediaUrlCache(),
       _mediaStorage = mediaStorage;

  final AppDatabase _db;
  final JoblensBackendApiClient? _backendApiClient;
  final SignedMediaUrlCache _signedMediaUrlCache;
  final MediaStorageService? _mediaStorage;
  bool _isRunning = false;

  Future<void> enqueueAsset(PhotoAsset asset) async {
    await _db.enqueueSyncJob(
      assetId: asset.id,
      projectId: asset.projectId,
      provider: CloudProviderType.backend,
    );
    await _logInfo(
      'asset_queued',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Queued asset for cloud sync.',
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

  Future<List<Project>> syncRemoteProjects(List<Project> localProjects) async {
    final client = _backendApiClient;
    if (client == null) {
      return localProjects;
    }

    final response = await client.listProjects();
    if (response.projects.isEmpty) {
      return localProjects;
    }

    var workingProjects = await _db.getProjects();
    final inboxMatches = workingProjects
        .where((project) => project.name == 'Inbox')
        .toList(growable: false);
    final inbox = inboxMatches.isEmpty ? null : inboxMatches.first;

    for (final remoteProject in response.projects) {
      final remoteProjectId = remoteProject.projectId.trim();
      if (remoteProjectId.isEmpty) {
        continue;
      }

      final existingLocalProjectId = await _db.getLocalProjectIdByRemoteId(
        remoteProjectId,
      );
      if (existingLocalProjectId != null) {
        final existing = workingProjects.firstWhere(
          (project) => project.id == existingLocalProjectId,
        );
        final normalizedName = existing.name == 'Inbox'
            ? 'Inbox'
            : remoteProject.name.trim().isEmpty
            ? existing.name
            : remoteProject.name.trim();
        if (existing.name != normalizedName) {
          await _db.updateProjectMetadata(
            existing.id,
            name: normalizedName,
            startDate: existing.startDate,
          );
        }
        continue;
      }

      if (remoteProject.name.trim() == 'Inbox' &&
          inbox != null &&
          (inbox.remoteProjectId == null || inbox.remoteProjectId!.isEmpty)) {
        await _db.updateProjectRemoteId(inbox.id, remoteProjectId);
        continue;
      }

      final existingByNameMatches = workingProjects
          .where(
            (project) =>
                (project.remoteProjectId == null ||
                    project.remoteProjectId!.isEmpty) &&
                project.name.trim() == remoteProject.name.trim(),
          )
          .toList(growable: false);
      final existingByName = existingByNameMatches.isEmpty
          ? null
          : existingByNameMatches.first;
      if (existingByName != null) {
        await _db.updateProjectRemoteId(existingByName.id, remoteProjectId);
        continue;
      }

      final localProjectId = await _db.createProject(remoteProject.name.trim());
      await _db.updateProjectRemoteId(localProjectId, remoteProjectId);
      await _logInfo(
        'remote_project_discovered',
        projectId: localProjectId,
        message: 'Discovered existing remote project "${remoteProject.name}".',
      );
      workingProjects = await _db.getProjects();
    }

    return await _db.getProjects();
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
      await _logInfo(
        'process_queue_start',
        message: 'Processing ${pending.length} pending sync job(s).',
      );

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
          await _logError(
            'asset_missing',
            assetId: entry.key,
            message: 'Asset no longer exists locally.',
          );
          await _markJobsFailed(
            jobs,
            errorCode: 'asset_missing',
            errorMessage: 'Asset no longer exists locally.',
          );
          continue;
        }

        final project = projectsById[asset.projectId];
        if (project == null) {
          await _logError(
            'project_missing',
            assetId: asset.id,
            message: 'Project ${asset.projectId} no longer exists locally.',
            projectId: asset.projectId,
          );
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
          await _logError(
            'project_sync_failed',
            assetId: asset.id,
            projectId: asset.projectId,
            message: mapped.message,
          );
          await _db.updateAssetSyncError(asset.id, mapped.code);
          await _markJobsFailed(
            jobs,
            errorCode: mapped.code,
            errorMessage: mapped.message,
          );
          continue;
        }

        if (remoteProjectId.isEmpty) {
          await _logError(
            'project_sync_failed',
            assetId: asset.id,
            projectId: asset.projectId,
            message: 'Unable to create or resolve backend project.',
          );
          await _db.updateAssetSyncError(asset.id, 'project_sync_failed');
          await _markJobsFailed(
            jobs,
            errorCode: 'project_sync_failed',
            errorMessage: 'Unable to create or resolve backend project.',
          );
          continue;
        }

        final existingRemoteAssetId = asset.remoteAssetId?.trim() ?? '';
        if (existingRemoteAssetId.isNotEmpty) {
          try {
            await _moveExistingRemoteAsset(
              asset,
              jobs,
              remoteAssetId: existingRemoteAssetId,
              remoteProjectId: remoteProjectId,
            );
          } catch (error) {
            final mapped = _mapSyncError(error);
            await _logError(
              'remote_move_failed',
              assetId: asset.id,
              projectId: asset.projectId,
              message: mapped.message,
            );
            await _db.updateAssetSyncError(asset.id, mapped.code);
            await _markJobsFailed(
              jobs,
              errorCode: mapped.code,
              errorMessage: mapped.message,
            );
          }
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
              await _logError(
                'bulk_check_failed',
                assetId: item.asset.id,
                projectId: item.asset.projectId,
                message: mapped.message,
              );
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
              await _logError(
                'bulk_check_missing_result',
                assetId: item.asset.id,
                projectId: item.asset.projectId,
                message: 'Backend did not return a bulk-check result for this asset.',
              );
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
              try {
                await _handleDuplicate(
                  item,
                  result.assetId,
                  remoteProjectId: remoteProjectId,
                );
              } catch (error) {
                final mapped = _mapSyncError(error);
                await _logError(
                  'duplicate_move_failed',
                  assetId: item.asset.id,
                  projectId: item.asset.projectId,
                  message: mapped.message,
                );
                await _db.updateAssetSyncError(item.asset.id, mapped.code);
                await _markJobsFailed(
                  item.jobs,
                  errorCode: mapped.code,
                  errorMessage: mapped.message,
                );
              }
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

  Future<void> deleteRemoteAsset(PhotoAsset asset) async {
    final client = _backendApiClient;
    final remoteAssetId = asset.remoteAssetId;
    if (client == null || remoteAssetId == null || remoteAssetId.isEmpty) {
      return;
    }

    await client.deleteAsset(remoteAssetId);
    await _logInfo(
      'remote_delete_requested',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Requested remote delete for synced asset.',
    );
    await invalidateThumbnailUrl(asset);
    await invalidateDownloadUrl(asset);
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
      if (!remoteAsset.deleted && existingByHash.localPath.isEmpty) {
        await _downloadRemoteAssetLocally(
          existingByHash.copyWith(
            projectId: localProjectId,
            cloudState: cloudState,
            remoteAssetId: remoteAsset.assetId,
            remoteProvider: remoteAsset.provider?.key,
            remoteFileId: remoteAsset.remoteFileId,
            uploadPath: remoteAsset.remotePath,
            lastSyncErrorCode: null,
          ),
          remoteAsset: remoteAsset,
        );
      }
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
    if (!remoteAsset.deleted) {
      final localAsset = await _db.getAssetByRemoteId(remoteAsset.assetId);
      if (localAsset != null) {
        await _downloadRemoteAssetLocally(localAsset, remoteAsset: remoteAsset);
      }
    }
  }

  Future<void> _downloadRemoteAssetLocally(
    PhotoAsset asset, {
    required BackendAssetRecord remoteAsset,
  }) async {
    final client = _backendApiClient;
    final mediaStorage = _mediaStorage;
    if (client == null || mediaStorage == null) {
      return;
    }
    if (asset.localPath.isNotEmpty || asset.status == AssetStatus.deleted) {
      return;
    }
    final remoteAssetId = asset.remoteAssetId;
    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      return;
    }

    try {
      final bytes = await client.downloadAssetBytes(remoteAssetId);
      final stored = await mediaStorage.storeDownloadedBytes(
        assetId: asset.id,
        bytes: bytes,
        filename: remoteAsset.filename,
      );
      await _db.updateAssetLocalMedia(
        assetId: asset.id,
        localPath: stored.localPath,
        thumbPath: stored.thumbPath,
        hash: stored.hash,
        cloudState: AssetCloudState.localAndCloud,
      );
      await _logInfo(
        'remote_asset_downloaded',
        assetId: asset.id,
        projectId: asset.projectId,
        message: 'Downloaded remote asset to local storage.',
      );
    } catch (error) {
      final mapped = _mapSyncError(error);
      await _db.updateAssetSyncError(asset.id, mapped.code);
      await _logError(
        'remote_asset_download_failed',
        assetId: asset.id,
        projectId: asset.projectId,
        message: mapped.message,
      );
    }
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
      await _logInfo(
        'remote_move_completed',
        assetId: context.asset.id,
        projectId: context.asset.projectId,
        message: 'Moved synced asset to its destination project folder.',
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
    await _logInfo(
      'duplicate_marked_synced',
      assetId: context.asset.id,
      projectId: context.asset.projectId,
      message: 'Matched an existing remote asset during sync.',
    );
    await _db.updateAssetSyncError(context.asset.id, null);
    await _markJobsDone(context.jobs);
  }

  Future<void> _moveExistingRemoteAsset(
    PhotoAsset asset,
    List<SyncJob> jobs, {
    required String remoteAssetId,
    required String remoteProjectId,
  }) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const ApiException(
        code: 'backend_unavailable',
        message: 'Backend API client is not configured.',
      );
    }

    await _markJobsUploading(jobs);
    final moved = await client.moveAssetToProject(
      assetId: remoteAssetId,
      projectId: remoteProjectId,
    );
    await _logInfo(
      'remote_move_completed',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Moved synced asset to its destination project folder.',
    );
    await _db.updateAssetCloudMetadata(
      assetId: asset.id,
      remoteAssetId: moved.assetId,
      remoteProvider: moved.provider?.key,
      remoteFileId: moved.remoteFileId,
      uploadPath: moved.remotePath,
      cloudState: AssetCloudState.localAndCloud,
      lastSyncErrorCode: null,
    );
    await _db.updateAssetSyncError(asset.id, null);
    await _markJobsDone(jobs);
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
      await _logInfo(
        'upload_completed',
        assetId: context.asset.id,
        projectId: context.asset.projectId,
        message: 'Uploaded asset to the cloud provider successfully.',
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
      await _logError(
        'upload_failed',
        assetId: context.asset.id,
        projectId: context.asset.projectId,
        message: mapped.message,
      );
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
        await _logInfo(
          'prepare_upload_duplicate',
          assetId: context.asset.id,
          projectId: context.asset.projectId,
          message: 'Backend reported that the asset already exists remotely.',
        );
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

      await _logInfo(
        'prepare_upload_ready',
        assetId: context.asset.id,
        projectId: context.asset.projectId,
        message: 'Upload instructions received from backend.',
      );

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

        await _logInfo(
          'commit_succeeded',
          assetId: context.asset.id,
          projectId: context.asset.projectId,
          message: 'Backend commit completed for uploaded asset.',
        );

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

  Future<void> _logInfo(
    String event, {
    String? assetId,
    int? projectId,
    required String message,
  }) async {
    await _db.addSyncLog(
      level: SyncLogLevel.info,
      event: event,
      assetId: assetId,
      projectId: projectId,
      message: message,
    );
    if (kDebugMode) {
      debugPrint('Joblens sync [$event] ${assetId ?? '-'} $message');
    }
  }

  Future<void> _logError(
    String event, {
    String? assetId,
    int? projectId,
    required String message,
  }) async {
    await _db.addSyncLog(
      level: SyncLogLevel.error,
      event: event,
      assetId: assetId,
      projectId: projectId,
      message: message,
    );
    if (kDebugMode) {
      debugPrint('Joblens sync ERROR [$event] ${assetId ?? '-'} $message');
    }
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
