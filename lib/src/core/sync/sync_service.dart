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
import '../models/provider_credentials.dart';
import '../models/sync_job.dart';
import 'adapters/adapter_factory.dart';
import 'cloud_adapter.dart';
import 'credential_store.dart';
import 'oauth/oauth_service.dart';

class SyncService {
  SyncService(
    this._db,
    this._credentialStore,
    this._oauthService, {
    JoblensBackendApiClient? backendApiClient,
    SignedMediaUrlCache? signedMediaUrlCache,
  }) : _backendApiClient = backendApiClient,
       _signedMediaUrlCache = signedMediaUrlCache ?? SignedMediaUrlCache();

  final AppDatabase _db;
  final CredentialStore _credentialStore;
  final OAuthService _oauthService;
  final JoblensBackendApiClient? _backendApiClient;
  final SignedMediaUrlCache _signedMediaUrlCache;
  bool _isRunning = false;
  static const Duration _refreshSkew = Duration(minutes: 2);

  Future<void> enqueueAsset(PhotoAsset asset) async {
    await _db.enqueueSyncJob(
      assetId: asset.id,
      projectId: asset.projectId,
      provider: CloudProviderType.backend,
    );
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
    final jobs = await _db.getSyncJobs();
    for (final job in jobs.where(
      (item) => item.providerType == provider && item.state == SyncJobState.paused,
    )) {
      await _db.updateSyncJob(
        job.copyWith(state: SyncJobState.queued, lastError: null),
      );
    }
  }

  Future<void> retryFailed() async {
    await _db.setAllFailedToQueued();
  }

  Future<void> validateProviderConnection(CloudProviderType provider) async {
    final creds = await _ensureUsableCredentials(
      provider,
      throwOnRefreshFailure: true,
    );
    final adapter = buildAdapter(creds);
    if (adapter == null) {
      throw CloudSyncException(
        '${provider.label} credentials are missing or incomplete.',
      );
    }

    await adapter.authenticate();
  }

  Future<ProviderCredentials?> readCredentials(CloudProviderType provider) {
    return _credentialStore.read(provider);
  }

  Future<void> saveCredentials(ProviderCredentials credentials) async {
    await _credentialStore.save(credentials.provider, credentials);
  }

  Future<void> clearCredentials(CloudProviderType provider) async {
    await _credentialStore.clear(provider);
  }

  Future<Map<CloudProviderType, bool>> credentialStatus() async {
    final status = await _credentialStore.hasCredentials();
    status[CloudProviderType.backend] = true;
    return status;
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
      final projectsById = {for (final project in projects) project.id: project};

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

        final remoteProjectId = project.remoteProjectId;
        if (remoteProjectId == null || remoteProjectId.trim().isEmpty) {
          await _db.updateAssetSyncError(asset.id, 'project_mapping_missing');
          await _markJobsFailed(
            jobs,
            errorCode: 'project_mapping_missing',
            errorMessage: 'Project is missing remote project mapping.',
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
              await _db.updateAssetSyncError(item.asset.id, 'bulk_check_missing_result');
              await _markJobsFailed(
                item.jobs,
                errorCode: 'bulk_check_missing_result',
                errorMessage: 'Backend did not return bulk-check result for this asset.',
              );
              continue;
            }

            if (result.isDuplicate) {
              await _handleDuplicate(item, result.assetId);
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
        if (project.remoteProjectId != null && project.remoteProjectId!.isNotEmpty)
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
    _signedMediaUrlCache.invalidate(remoteAssetId, SignedMediaUrlKind.thumbnail);
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
          status: remoteAsset.deleted ? AssetStatus.deleted : AssetStatus.active,
          cloudState: cloudState,
          remoteAssetId: remoteAsset.assetId,
          lastSyncErrorCode: null,
        ),
      );
      await _db.updateAssetCloudMetadata(
        assetId: existingByHash.id,
        remoteAssetId: remoteAsset.assetId,
        cloudState: cloudState,
        lastSyncErrorCode: null,
      );
      return;
    }

    await _db.upsertCloudOnlyAsset(
      localAssetId: 'remote:${remoteAsset.assetId}',
      projectId: localProjectId,
      remoteAssetId: remoteAsset.assetId,
      sha256: remoteAsset.sha256,
      createdAt: remoteAsset.takenAt ?? remoteAsset.createdAt ?? DateTime.now(),
      deleted: remoteAsset.deleted,
    );
  }

  Future<void> _handleDuplicate(
    _PendingAssetContext context,
    String? remoteAssetId,
  ) async {
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
        uploadSessionId: outcome.uploadSessionId,
        uploadPath: outcome.uploadPath,
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
      final uploadUrl = await client.requestUploadUrl(
        UploadUrlRequest(
          projectId: remoteProjectId,
          sha256: context.asset.hash,
          mediaType: 'photo',
          filename: filename,
          uploadSessionId: uploadSessionHint,
        ),
      );

      if (uploadUrl.isDuplicate) {
        return _UploadOutcome(
          remoteAssetId: uploadUrl.assetId ?? '',
          uploadSessionId: uploadUrl.uploadSessionId,
          uploadPath: uploadUrl.path,
        );
      }

      if (!uploadUrl.isUploadRequired ||
          uploadUrl.signedUrl == null ||
          uploadUrl.path == null) {
        throw const ApiException(
          code: 'invalid_upload_url_response',
          message: 'Upload URL response missing signed URL or path.',
        );
      }

      await client.uploadToSignedUrl(
        signedUrl: uploadUrl.signedUrl!,
        bytes: bytes,
        contentType: mimeType,
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
            uploadPath: uploadUrl.path!,
            uploadBucket: uploadUrl.bucket,
            uploadSessionId: uploadUrl.uploadSessionId,
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
          uploadSessionId: uploadUrl.uploadSessionId,
          uploadPath: uploadUrl.path,
        );
      } on ApiException catch (error) {
        if (error.code == 'uploaded_object_not_found' && !retriedMissingObject) {
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
    return _MappedSyncError(code: 'network_error', message: error.toString());
  }

  Future<ProviderCredentials?> _ensureUsableCredentials(
    CloudProviderType provider, {
    bool throwOnRefreshFailure = false,
  }) async {
    if (provider == CloudProviderType.backend) {
      return null;
    }

    var credentials = await _credentialStore.read(provider);
    if (credentials == null) {
      return null;
    }

    if (provider == CloudProviderType.nextcloud) {
      return credentials.isConfigured ? credentials : null;
    }

    if (!credentials.hasAccessToken) {
      credentials = await _tryRefresh(
        provider,
        credentials,
        throwOnFailure: throwOnRefreshFailure,
      );
      return credentials;
    }

    if (credentials.isAccessTokenExpiringSoon(skew: _refreshSkew) &&
        credentials.canRefreshAccessToken) {
      credentials = await _tryRefresh(
        provider,
        credentials,
        throwOnFailure: throwOnRefreshFailure,
      );
    }

    return credentials;
  }

  Future<ProviderCredentials?> _tryRefresh(
    CloudProviderType provider,
    ProviderCredentials current, {
    bool throwOnFailure = false,
  }) async {
    if (!current.canRefreshAccessToken) {
      return null;
    }

    try {
      final refreshed = await _oauthService.refreshAccessToken(current);
      await _credentialStore.save(provider, refreshed);
      return refreshed;
    } catch (_) {
      if (throwOnFailure) {
        rethrow;
      }
      return null;
    }
  }
}

class _PendingAssetContext {
  const _PendingAssetContext({
    required this.asset,
    required this.jobs,
  });

  final PhotoAsset asset;
  final List<SyncJob> jobs;
}

class _UploadOutcome {
  const _UploadOutcome({
    required this.remoteAssetId,
    required this.uploadSessionId,
    required this.uploadPath,
  });

  final String remoteAssetId;
  final String? uploadSessionId;
  final String? uploadPath;
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
