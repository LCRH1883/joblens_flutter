import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../api/api_exception.dart';
import '../api/backend_api_models.dart';
import '../api/joblens_backend_api_client.dart';
import '../api/signed_media_url_cache.dart';
import '../db/app_database.dart';
import '../models/backend_api_payloads.dart';
import '../models/backend_sync_event.dart';
import '../models/blob_upload_task.dart';
import '../models/cloud_provider.dart';
import '../models/entity_sync_record.dart';
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
  bool _runAgainRequested = false;
  static const int _maxParallelAssetOperations = 3;

  Future<void> kick({bool forceBootstrap = false}) async {
    if (_isRunning) {
      _runAgainRequested = true;
      return;
    }

    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    _isRunning = true;
    try {
      do {
        _runAgainRequested = false;
        await _db.cleanupSyncState();
        await _runVoidLaneSafely(
          'device_registration_failed',
          () => _ensureDeviceRegistration(),
        );
        if (forceBootstrap || !await _db.hasCompletedBootstrap()) {
          await _runVoidLaneSafely(
            'bootstrap_failed',
            () => _bootstrapFromBackend(),
          );
        }
        await _runVoidLaneSafely(
          'local_sync_backfill_failed',
          () => _backfillLocalSyncState(),
        );
        final pushedMetadata = await _pushMetadata();
        final advancedUploads = await _advanceBlobUploads();
        final pulledEvents = await _runLaneSafely<bool>(
          'remote_event_pull_failed',
          () => _pullRemoteEvents(),
          fallback: false,
        );
        if (pushedMetadata || advancedUploads || pulledEvents) {
          _runAgainRequested = true;
        }
      } while (_runAgainRequested);
    } finally {
      _isRunning = false;
    }
  }

  Future<T> _runLaneSafely<T>(
    String event,
    Future<T> Function() action, {
    required T fallback,
  }) async {
    try {
      return await action();
    } catch (error) {
      final mapped = _mapSyncError(error);
      await _logError(event, message: mapped.message);
      return fallback;
    }
  }

  Future<void> _runVoidLaneSafely(
    String event,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      final mapped = _mapSyncError(error);
      await _logError(event, message: mapped.message);
    }
  }

  Future<void> _ensureDeviceRegistration() async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    final existing = await _db.getBackendDeviceId();
    if (existing != null && existing.trim().isNotEmpty) {
      return;
    }

    final clientDeviceId = await _db.getOrCreateClientDeviceId();
    final backendDeviceId = await client.registerDevice(
      clientDeviceId: clientDeviceId,
      platform: Platform.operatingSystem,
      deviceName: Platform.localHostname,
    );
    await _db.setBackendDeviceId(backendDeviceId);
  }

  Future<void> _backfillLocalSyncState() async {
    final queuedProjects = await _db.backfillEligibleProjectSyncRecords();
    if (queuedProjects > 0) {
      await _logInfo(
        'local_project_backfill_queued',
        message:
            'Queued $queuedProjects existing local project${queuedProjects == 1 ? '' : 's'} for backend sync.',
      );
    }

    final providers = await _db.getProviderAccounts();
    final hasActiveCloudConnection = providers.any(
      (provider) =>
          provider.providerType != CloudProviderType.backend &&
          provider.hasActiveConnection,
    );
    if (!hasActiveCloudConnection) {
      return;
    }
    final queued = await _db.backfillEligibleBlobUploads();
    if (queued <= 0) {
      return;
    }
    await _logInfo(
      'local_upload_backfill_queued',
      message:
          'Queued $queued existing local asset${queued == 1 ? '' : 's'} for background cloud upload.',
    );
  }

  Future<void> _bootstrapFromBackend() async {
    await refreshProviderConnections();
    final projects = await syncRemoteProjects(await _db.getProjects(includeDeleted: true));
    await mergeRemoteAssets(projects);
    await _db.markBootstrapCompleted();
    await _logInfo(
      'bootstrap_completed',
      message: 'Bootstrapped local state from backend projects and assets.',
    );
  }

  Future<bool> _pushMetadata() async {
    final records = await _db.getPendingEntitySyncRecords();
    if (records.isEmpty) {
      return false;
    }

    for (final record in records) {
      await _db.leaseEntitySync(record.entityType, record.entityId);
      try {
        await _processEntitySyncRecord(record);
      } catch (error) {
        final mapped = _mapSyncError(error);
        await _db.failEntitySync(
          record.entityType,
          record.entityId,
          '[${mapped.code}] ${mapped.message}',
        );
        if (record.entityType == SyncEntityType.asset) {
          await _db.updateAssetSyncError(record.entityId, mapped.code);
        }
        await _logError(
          'metadata_sync_failed',
          assetId: record.entityType == SyncEntityType.asset ? record.entityId : null,
          projectId: record.entityType == SyncEntityType.project
              ? int.tryParse(record.entityId)
              : null,
          message: mapped.message,
        );
      }
    }
    return true;
  }

  Future<void> _processEntitySyncRecord(EntitySyncRecord record) async {
    switch (record.entityType) {
      case SyncEntityType.project:
        await _pushProjectRecord(record);
        break;
      case SyncEntityType.asset:
        await _pushAssetRecord(record);
        break;
    }
  }

  Future<void> _pushProjectRecord(EntitySyncRecord record) async {
    final projectId = int.tryParse(record.entityId);
    if (projectId == null) {
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    final project = await _db.getProjectById(projectId);
    if (project == null) {
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    if (project.deletedAt != null) {
      if (project.remoteProjectId != null && project.remoteProjectId!.isNotEmpty) {
        await archiveProject(project.remoteProjectId!);
      }
      await _db.markProjectSynced(
        project.id,
        remoteProjectId: project.remoteProjectId,
        remoteRev: project.remoteRev,
      );
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    final remoteProjectId = await syncProject(project);
    if (remoteProjectId != null && remoteProjectId.isNotEmpty) {
      await _db.completeEntitySync(record.entityType, record.entityId);
    }
  }

  Future<void> _pushAssetRecord(EntitySyncRecord record) async {
    final asset = await _db.getAssetById(record.entityId);
    if (asset == null) {
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    if (asset.status == AssetStatus.deleted || asset.deletedAt != null) {
      final remoteAssetId = asset.remoteAssetId?.trim();
      if (remoteAssetId == null || remoteAssetId.isEmpty) {
        await _db.completeEntitySync(record.entityType, record.entityId);
        return;
      }

      await deleteRemoteAsset(asset);
      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        cloudState: AssetCloudState.deleted,
        lastSyncErrorCode: null,
        dirtyFields: const [],
      );
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    final remoteAssetId = asset.remoteAssetId?.trim();
    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      await _db.completeEntitySync(record.entityType, record.entityId);
      return;
    }

    final remoteProjectId = await _ensureProjectRemoteId(asset.projectId);
    final moved = await _backendApiClient!.moveAssetToProject(
      assetId: remoteAssetId,
      projectId: remoteProjectId,
      expectedRevision: asset.remoteRev,
    );
    await _db.updateAssetCloudMetadata(
      assetId: asset.id,
      remoteAssetId: moved.assetId,
      remoteProvider: moved.provider?.key,
      remoteFileId: moved.remoteFileId,
      uploadPath: moved.remotePath,
      cloudState: AssetCloudState.localAndCloud,
      lastSyncErrorCode: null,
      remoteRev: moved.revision,
      dirtyFields: const [],
    );
    await _db.completeEntitySync(record.entityType, record.entityId);
  }

  Future<bool> _advanceBlobUploads() async {
    final tasks = await _db.getPendingBlobUploadTasks();
    if (tasks.isEmpty) {
      return false;
    }

    await _forEachWithConcurrency(tasks, _maxParallelAssetOperations, (task) async {
      await _processBlobUploadTask(task);
    });
    return true;
  }

  Future<void> _processBlobUploadTask(BlobUploadTask task) async {
    final asset = await _db.getAssetById(task.assetId);
    if (asset == null) {
      await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
      return;
    }
    if (asset.status == AssetStatus.deleted ||
        asset.deletedAt != null ||
        asset.uploadGeneration != task.uploadGeneration) {
      await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
      return;
    }
    if (asset.remoteAssetId != null && asset.remoteAssetId!.trim().isNotEmpty) {
      await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
      await _db.completeEntitySync(SyncEntityType.asset, task.assetId);
      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
        dirtyFields: const [],
      );
      return;
    }

    await _db.markBlobUploadUploading(task.assetId, task.uploadGeneration);

    final remoteProjectId = await _ensureProjectRemoteId(asset.projectId);
    final context = _PendingAssetContext(asset: asset, jobs: const []);
    try {
      final bulkCheck = await _backendApiClient!.bulkCheckAssets(
        projectId: remoteProjectId,
        assets: [
          BulkCheckAssetInput(deviceAssetId: asset.id, sha256: asset.hash),
        ],
      );
      final result = bulkCheck.results.cast<BulkCheckResult?>().firstOrNull;
      if (result != null && result.isDuplicate) {
        await _handleDuplicate(
          context,
          result.assetId,
          remoteProjectId: remoteProjectId,
        );
        await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
        await _db.completeEntitySync(SyncEntityType.asset, task.assetId);
        await _db.updateAssetCloudMetadata(
          assetId: asset.id,
          cloudState: AssetCloudState.localAndCloud,
          lastSyncErrorCode: null,
          dirtyFields: const [],
        );
        return;
      }

      final outcome = await _uploadAndCommitWithRetry(
        context,
        remoteProjectId: remoteProjectId,
      );
      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        remoteAssetId: outcome.remoteAssetId,
        remoteProvider: outcome.remoteProvider?.key,
        remoteFileId: outcome.remoteFileId,
        uploadSessionId: outcome.uploadSessionId,
        uploadPath: outcome.remotePath,
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
        dirtyFields: const [],
      );
      await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
      await _db.completeEntitySync(SyncEntityType.asset, task.assetId);
      await _db.updateAssetSyncError(asset.id, null);
      await _logInfo(
        'upload_completed',
        assetId: asset.id,
        projectId: asset.projectId,
        message: 'Uploaded asset to the cloud provider successfully.',
      );
    } catch (error) {
      final recovered = await _recoverDuplicateUploadFailure(
        context,
        remoteProjectId: remoteProjectId,
        error: error,
      );
      if (recovered) {
        await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
        await _db.completeEntitySync(SyncEntityType.asset, task.assetId);
        await _db.updateAssetCloudMetadata(
          assetId: asset.id,
          cloudState: AssetCloudState.localAndCloud,
          lastSyncErrorCode: null,
          dirtyFields: const [],
        );
        return;
      }
      final mapped = _mapSyncError(error);
      await _db.failBlobUpload(
        task.assetId,
        task.uploadGeneration,
        '[${mapped.code}] ${mapped.message}',
      );
      await _db.updateAssetSyncError(asset.id, mapped.code);
      await _logError(
        'upload_failed',
        assetId: asset.id,
        projectId: asset.projectId,
        message: mapped.message,
      );
    }
  }

  Future<bool> _pullRemoteEvents() async {
    final client = _backendApiClient;
    if (client == null) {
      return false;
    }

    var after = await _db.getLastSyncEventId();
    var sawEvents = false;
    do {
      final response = await client.getSyncEvents(after: after);
      if (response.events.isEmpty) {
        return sawEvents;
      }
      sawEvents = true;
      var needsSnapshotRefresh = false;
      for (final event in response.events) {
        final applied = await _applyRemoteEvent(event);
        if (!applied) {
          needsSnapshotRefresh = true;
        }
      }
      if (needsSnapshotRefresh) {
        final projects = await syncRemoteProjects(await _db.getProjects(includeDeleted: true));
        await mergeRemoteAssets(projects);
      }

      after = response.nextAfter;
      await _db.setLastSyncEventId(after);
      final backendDeviceId = await _db.getBackendDeviceId();
      if (backendDeviceId != null && backendDeviceId.trim().isNotEmpty) {
        await client.ackSyncEvents(
          deviceId: backendDeviceId,
          upToEventId: after,
        );
      }
      if (!response.hasMore) {
        break;
      }
    } while (true);
    return sawEvents;
  }

  Future<bool> _applyRemoteEvent(BackendSyncEvent event) async {
    switch (event.eventType) {
      case 'provider_connection_upsert':
      case 'provider_connection_deleted':
        return _applyProviderConnectionEvent(event);
      case 'project_provider_mirror_upsert':
        return _applyProjectProviderMirrorEvent(event);
      case 'asset_provider_mirror_upsert':
        return _applyAssetProviderMirrorEvent(event);
      case 'project_created':
      case 'project_updated':
      case 'project_deleted':
      case 'project_archived':
        return _applyRemoteProjectEvent(event);
      case 'asset_committed':
      case 'asset_moved':
      case 'asset_deleted':
      case 'asset_restored':
        return _applyRemoteAssetEvent(event);
      default:
        return false;
    }
  }

  Future<bool> _applyProviderConnectionEvent(BackendSyncEvent event) async {
    final connectionPayload = toObjectMap(event.payload['connection']);
    if (connectionPayload.isEmpty) {
      return false;
    }
    final providerKey = _payloadString(connectionPayload, ['provider'])?.trim();
    if (providerKey == null || providerKey.isEmpty) {
      return false;
    }
    final provider = CloudProviderTypeX.fromKey(providerKey);
    await _db.updateProviderAccountStatus(
      provider,
      connectionStatus: ProviderConnectionStatus.fromStorage(
        switch (_payloadString(connectionPayload, ['status'])?.trim()) {
          'connected' => ProviderConnectionStatus.ready.storageValue,
          'expired' => ProviderConnectionStatus.reconnectRequired.storageValue,
          final value? => value,
          null => ProviderConnectionStatus.disconnected.storageValue,
        },
      ),
      connectionId: _payloadString(connectionPayload, ['connectionId', 'connection_id']),
      connectedAt: _payloadDateTime(connectionPayload, ['connectedAt', 'connected_at']),
      displayName: _payloadString(connectionPayload, ['displayName', 'display_name']),
      accountIdentifier: _payloadString(connectionPayload, ['accountIdentifier', 'account_identifier']),
      rootDisplayName: _payloadString(connectionPayload, ['rootDisplayName', 'root_display_name']),
      rootFolderPath: _payloadString(connectionPayload, ['rootFolderPath', 'root_folder_path']),
      lastError: _payloadString(connectionPayload, ['lastError', 'last_error']),
      isActive: _payloadBool(connectionPayload, ['isActive', 'is_active']) &&
          !_payloadBool(connectionPayload, ['deleted']),
    );
    return true;
  }

  Future<bool> _applyProjectProviderMirrorEvent(BackendSyncEvent event) async {
    final mirrorPayload = toObjectMap(event.payload['projectMirror']);
    if (mirrorPayload.isEmpty) {
      return false;
    }
    final remoteProjectId =
        _payloadString(mirrorPayload, ['projectId', 'project_id'])?.trim();
    final providerConnectionId =
        _payloadString(mirrorPayload, ['providerConnectionId', 'provider_connection_id'])?.trim();
    if (remoteProjectId == null ||
        remoteProjectId.isEmpty ||
        providerConnectionId == null ||
        providerConnectionId.isEmpty) {
      return false;
    }
    final localProjectId = await _db.getLocalProjectIdByRemoteId(remoteProjectId);
    if (localProjectId == null) {
      return false;
    }
    await _db.upsertProjectProviderMirror(
      localProjectId: localProjectId,
      providerConnectionId: providerConnectionId,
      status: _payloadString(mirrorPayload, ['status']) ?? 'pending',
      providerFolderId: _payloadString(mirrorPayload, ['providerFolderId', 'provider_folder_id']),
      providerRev: _payloadString(mirrorPayload, ['providerRev', 'provider_rev']),
      lastError: _payloadString(mirrorPayload, ['lastError', 'last_error']),
    );
    return true;
  }

  Future<bool> _applyAssetProviderMirrorEvent(BackendSyncEvent event) async {
    final mirrorPayload = toObjectMap(event.payload['assetMirror']);
    if (mirrorPayload.isEmpty) {
      return false;
    }
    final remoteAssetId =
        _payloadString(mirrorPayload, ['assetId', 'asset_id'])?.trim();
    final providerConnectionId =
        _payloadString(mirrorPayload, ['providerConnectionId', 'provider_connection_id'])?.trim();
    if (remoteAssetId == null ||
        remoteAssetId.isEmpty ||
        providerConnectionId == null ||
        providerConnectionId.isEmpty) {
      return false;
    }
    final asset = await _db.getAssetByRemoteId(remoteAssetId);
    if (asset == null) {
      return false;
    }
    await _db.upsertAssetProviderMirror(
      assetId: asset.id,
      providerConnectionId: providerConnectionId,
      status: _payloadString(mirrorPayload, ['status']) ?? 'pending',
      providerFileId: _payloadString(mirrorPayload, ['providerFileId', 'provider_file_id']),
      remotePath: _payloadString(mirrorPayload, ['remotePath', 'remote_path']),
      providerRev: _payloadString(mirrorPayload, ['providerRev', 'provider_rev']),
      lastError: _payloadString(mirrorPayload, ['lastError', 'last_error']),
    );
    return true;
  }

  Future<bool> _applyRemoteProjectEvent(BackendSyncEvent event) async {
    final projectPayload = toObjectMap(event.payload['project']);
    if (projectPayload.isEmpty) {
      return false;
    }

    final remoteProjectId =
        _payloadString(projectPayload, ['projectId', 'id'])?.trim();
    if (remoteProjectId == null || remoteProjectId.isEmpty) {
      return false;
    }

    await _db.upsertRemoteProjectSnapshot(
      remoteProjectId: remoteProjectId,
      name: _payloadString(projectPayload, ['name'])?.trim().isNotEmpty == true
          ? _payloadString(projectPayload, ['name'])!.trim()
          : 'Inbox',
      remoteRev: _payloadInt(projectPayload, ['revision', 'remote_rev']),
      deleted:
          _payloadBool(projectPayload, ['deleted']) ||
          event.eventType == 'project_deleted' ||
          event.eventType == 'project_archived',
    );
    return true;
  }

  Future<bool> _applyRemoteAssetEvent(BackendSyncEvent event) async {
    final assetPayload = toObjectMap(event.payload['asset']);
    if (assetPayload.isEmpty) {
      return false;
    }

    final remoteProjectId =
        (_payloadString(assetPayload, ['projectId', 'project_id']) ??
                event.projectId)
            ?.trim();
    if (remoteProjectId == null || remoteProjectId.isEmpty) {
      return false;
    }

    final localProjectId = await _db.getLocalProjectIdByRemoteId(
      remoteProjectId,
    );
    if (localProjectId == null) {
      return false;
    }

    final normalizedAssetPayload = Map<String, dynamic>.from(assetPayload);
    normalizedAssetPayload['projectId'] = remoteProjectId;
    if (event.eventType == 'asset_deleted') {
      normalizedAssetPayload['deleted'] = true;
    } else if (event.eventType == 'asset_restored') {
      normalizedAssetPayload['deleted'] = false;
    }

    if (_payloadString(normalizedAssetPayload, ['assetId', 'id']) == null ||
        _payloadString(normalizedAssetPayload, ['sha256', 'hash']) == null) {
      return false;
    }

    await _mergeRemoteAsset(
      BackendAssetRecord.fromMap(normalizedAssetPayload),
      fallbackLocalProjectId: localProjectId,
    );
    return true;
  }

  String? _payloadString(Map<String, Object?> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  int? _payloadInt(Map<String, Object?> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  DateTime? _payloadDateTime(Map<String, Object?> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is DateTime) {
        return value;
      }
      if (value is String) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  bool _payloadBool(Map<String, Object?> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is bool) {
        return value;
      }
      if (value is num) {
        return value != 0;
      }
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') {
          return true;
        }
        if (normalized == 'false' || normalized == '0') {
          return false;
        }
      }
    }
    return false;
  }

  Future<String> _ensureProjectRemoteId(int projectId) async {
    final project = await _db.getProjectById(projectId);
    if (project == null) {
      throw ApiException(
        code: 'project_missing',
        message: 'Project $projectId no longer exists locally.',
      );
    }
    final existing = project.remoteProjectId?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final synced = await syncProject(project);
    if (synced == null || synced.trim().isEmpty) {
      throw const ApiException(
        code: 'project_sync_failed',
        message: 'Unable to sync project before asset upload.',
      );
    }
    return synced;
  }

  Future<void> enqueueAsset(PhotoAsset asset) async {
    await _db.upsertBlobUploadTask(
      assetId: asset.id,
      uploadGeneration: asset.uploadGeneration,
      localUri: asset.localPath,
    );
    await _logInfo(
      'asset_queued',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Queued asset for background blob upload.',
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
        connectionStatus: ProviderConnectionStatus.disconnected,
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
    await _db.cleanupSyncState();
    final syncRecords = await _db.getAllEntitySyncRecords();
    for (final record in syncRecords.where((item) => item.hasError)) {
      await _db.upsertEntitySync(
        entityType: record.entityType,
        entityId: record.entityId,
        dirtyFields: record.dirtyFields,
        baseRemoteRev: record.baseRemoteRev,
        localSeq: record.localSeq,
      );
    }
    final uploads = await _db.getAllBlobUploadTasks();
    for (final task in uploads.where((item) => item.state == BlobUploadState.failed)) {
      await _db.upsertBlobUploadTask(
        assetId: task.assetId,
        uploadGeneration: task.uploadGeneration,
        localUri: task.localUri,
      );
    }
  }

  Future<void> refreshProviderConnections() async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    final response = await client.listProviderConnections();
    for (final connection in response.connections) {
      await _db.updateProviderAccountStatus(
        connection.provider,
        connectionStatus: ProviderConnectionStatus.fromStorage(
          switch (connection.status) {
            'connected' => ProviderConnectionStatus.ready.storageValue,
            'expired' => ProviderConnectionStatus.reconnectRequired.storageValue,
            _ => connection.status,
          },
        ),
        connectionId: connection.connectionId,
        connectedAt: connection.connectedAt,
        displayName: connection.displayName,
        accountIdentifier: connection.accountIdentifier,
        rootDisplayName: connection.rootDisplayName,
        rootFolderPath: connection.rootFolderPath,
        lastError: connection.lastError,
        isActive: connection.isActive,
      );
    }
  }

  Future<String> beginProviderConnection(
    CloudProviderType provider, {
    required String intent,
    String? oldConnectionId,
  }) async {
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
    final response = await client.beginProviderConnection(
      provider,
      intent: intent,
      oldConnectionId: oldConnectionId,
      appInstallId: await _db.getBackendDeviceId(),
      devicePlatform: Platform.operatingSystem,
    );
    return response.authorizationUrl;
  }

  Future<ProviderAuthSessionResult> completeProviderConnection(
    String sessionId,
  ) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    final result = await client.getProviderAuthSessionResult(sessionId);
    await _db.updateProviderAccountStatus(
      result.provider,
      connectionStatus: ProviderConnectionStatus.fromStorage(
        result.connectionStatus ??
            switch (result.status) {
              'completed' => ProviderConnectionStatus.connectedBootstrapping.storageValue,
              _ => ProviderConnectionStatus.failed.storageValue,
            },
      ),
      connectionId: result.connectionId,
      connectedAt: DateTime.now(),
      displayName: result.displayName,
      accountIdentifier: result.providerAccountEmail,
      rootDisplayName: result.rootDisplayName,
      rootFolderPath: result.rootFolderPath,
      lastError: result.lastError,
      isActive: result.status == 'completed',
    );
    return result;
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
      connectionStatus: ProviderConnectionStatus.disconnected,
      displayName: provider.label,
      accountIdentifier: null,
      connectionId: null,
      rootDisplayName: null,
      rootFolderPath: null,
      lastError: null,
      isActive: false,
    );
  }

  Future<void> reconcileProject(Project project) async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    final remoteProjectId = project.remoteProjectId?.trim();
    if (remoteProjectId == null || remoteProjectId.isEmpty) {
      throw const CloudSyncException('Project is not synced to the cloud yet.');
    }
    await client.reconcileProject(remoteProjectId);
    await _logInfo(
      'project_reconcile_requested',
      projectId: project.id,
      message: 'Requested a cloud reconcile for this project.',
    );
  }

  Future<int> reconcileProjects(Iterable<Project> projects) async {
    final syncableProjects = projects
        .where((project) => (project.remoteProjectId?.trim().isNotEmpty ?? false))
        .toList(growable: false);
    if (syncableProjects.isEmpty) {
      return 0;
    }
    for (final project in syncableProjects) {
      await reconcileProject(project);
    }
    return syncableProjects.length;
  }

  Future<void> deleteAccount() async {
    final client = _backendApiClient;
    if (client == null) {
      throw const CloudSyncException('Backend API client is not configured.');
    }
    await client.deleteAccount();
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
        expectedRevision: project.remoteRev,
      ),
    );
    await _db.markProjectSynced(
      project.id,
      remoteProjectId: response.projectId,
      remoteRev: response.revision,
    );
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

    var workingProjects = await _db.getProjects(includeDeleted: true);
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
        await _db.upsertRemoteProjectSnapshot(
          remoteProjectId: remoteProjectId,
          name: remoteProject.name.trim().isEmpty ? 'Inbox' : remoteProject.name.trim(),
          remoteRev: remoteProject.revision,
          deleted: remoteProject.deleted,
        );
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
        await _db.markProjectSynced(
          existingByName.id,
          remoteProjectId: remoteProjectId,
          remoteRev: remoteProject.revision,
        );
        continue;
      }

      final localProjectId = await _db.upsertRemoteProjectSnapshot(
        remoteProjectId: remoteProjectId,
        name: remoteProject.name.trim(),
        remoteRev: remoteProject.revision,
        deleted: remoteProject.deleted,
      );
      await _logInfo(
        'remote_project_discovered',
        projectId: localProjectId,
        message: 'Discovered existing remote project "${remoteProject.name}".',
      );
      workingProjects = await _db.getProjects(includeDeleted: true);
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
    await kick();
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

    await client.deleteAsset(
      remoteAssetId,
      expectedRevision: asset.remoteRev,
    );
    await _logInfo(
      'remote_delete_requested',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Requested remote delete for synced asset.',
    );
    await invalidateThumbnailUrl(asset);
    await invalidateDownloadUrl(asset);
  }

  Future<void> flushPendingRemoteDeletes() async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }

    final deletedAssets = await _db.getDeletedAssetsPendingRemoteDelete();
    for (final asset in deletedAssets) {
      final remoteAssetId = asset.remoteAssetId;
      if (remoteAssetId == null || remoteAssetId.isEmpty) {
        continue;
      }

      try {
        await client.deleteAsset(
          remoteAssetId,
          expectedRevision: asset.remoteRev,
        );
        await _db.updateAssetCloudMetadata(
          assetId: asset.id,
          cloudState: AssetCloudState.deleted,
          lastSyncErrorCode: null,
        );
        await _logInfo(
          'remote_delete_synced',
          assetId: asset.id,
          projectId: asset.projectId,
          message: 'Confirmed backend delete for locally deleted asset.',
        );
        await invalidateThumbnailUrl(asset);
        await invalidateDownloadUrl(asset);
      } catch (error) {
        final mapped = _mapSyncError(error);
        await _db.updateAssetSyncError(asset.id, mapped.code);
        await _logError(
          'remote_delete_retry_failed',
          assetId: asset.id,
          projectId: asset.projectId,
          message: mapped.message,
        );
      }
    }
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
      if (existingByHash.status == AssetStatus.deleted && !remoteAsset.deleted) {
        await _db.updateAssetCloudMetadata(
          assetId: existingByHash.id,
          remoteAssetId: remoteAsset.assetId,
          remoteProvider: remoteAsset.provider?.key,
          remoteFileId: remoteAsset.remoteFileId,
          uploadPath: remoteAsset.remotePath,
          cloudState: AssetCloudState.deleted,
        );
        await _logInfo(
          'remote_delete_preserved',
          assetId: existingByHash.id,
          projectId: existingByHash.projectId,
          message:
              'Preserved local deletion while waiting for backend/cloud delete to converge.',
        );
        return;
      }

      final cloudState = remoteAsset.deleted
          ? AssetCloudState.deleted
          : existingByHash.localPath.isEmpty
          ? AssetCloudState.cloudOnly
          : AssetCloudState.localAndCloud;
      await _db.applyRemoteAssetSnapshot(
        localAssetId: existingByHash.id,
        projectId: localProjectId,
        remoteAssetId: remoteAsset.assetId,
        sha256: remoteAsset.sha256,
        createdAt: remoteAsset.takenAt ?? remoteAsset.createdAt ?? DateTime.now(),
        remoteRev: remoteAsset.revision,
        filename: remoteAsset.filename,
        remoteProvider: remoteAsset.provider?.key,
        remoteFileId: remoteAsset.remoteFileId,
        remotePath: remoteAsset.remotePath,
        deleted: remoteAsset.deleted,
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

    await _db.applyRemoteAssetSnapshot(
      localAssetId: 'remote:${remoteAsset.assetId}',
      projectId: localProjectId,
      remoteAssetId: remoteAsset.assetId,
      sha256: remoteAsset.sha256,
      createdAt: remoteAsset.takenAt ?? remoteAsset.createdAt ?? DateTime.now(),
      remoteRev: remoteAsset.revision,
      filename: remoteAsset.filename,
      remoteProvider: remoteAsset.provider?.key,
      remoteFileId: remoteAsset.remoteFileId,
      remotePath: remoteAsset.remotePath,
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

  Future<bool> _recoverDuplicateUploadFailure(
    _PendingAssetContext context, {
    required String remoteProjectId,
    required Object error,
  }) async {
    if (!_isDuplicateCommitError(error)) {
      return false;
    }

    final client = _backendApiClient;
    if (client == null) {
      return false;
    }

    final remoteAssetId = await _resolveDuplicateAssetId(
      client: client,
      asset: context.asset,
      remoteProjectId: remoteProjectId,
    );
    if (remoteAssetId == null) {
      await _logError(
        'commit_duplicate_unresolved',
        assetId: context.asset.id,
        projectId: context.asset.projectId,
        message:
            'Duplicate upload was detected but bulk-check did not resolve an existing remote asset.',
      );
      return false;
    }

    await _handleDuplicate(
      context,
      remoteAssetId,
      remoteProjectId: remoteProjectId,
    );
    await _logInfo(
      'commit_duplicate_recovered',
      assetId: context.asset.id,
      projectId: context.asset.projectId,
      message:
          'Recovered duplicate upload by resolving the existing remote asset.',
    );
    return true;
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
            expectedRevision: context.asset.remoteRev,
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
        final duplicateOutcome = await _recoverDuplicateCommitCollision(
          client: client,
          asset: context.asset,
          remoteProjectId: remoteProjectId,
          prepared: prepared,
          remotePath: remotePath,
          error: error,
        );
        if (duplicateOutcome != null) {
          await _logInfo(
            'commit_duplicate_recovered',
            assetId: context.asset.id,
            projectId: context.asset.projectId,
            message:
                'Recovered duplicate upload by resolving the existing remote asset.',
          );
          return duplicateOutcome;
        }
        rethrow;
      }
    }
  }

  Future<_UploadOutcome?> _recoverDuplicateCommitCollision({
    required JoblensBackendApiClient client,
    required PhotoAsset asset,
    required String remoteProjectId,
    required PrepareAssetUploadResponse prepared,
    required String remotePath,
    required ApiException error,
  }) async {
    if (!_isDuplicateCommitCollision(error)) {
      return null;
    }

    final remoteAssetId = await _resolveDuplicateAssetId(
      client: client,
      asset: asset,
      remoteProjectId: remoteProjectId,
    );
    if (remoteAssetId == null) {
      return null;
    }

    return _UploadOutcome(
      remoteAssetId: remoteAssetId,
      remoteProvider: prepared.provider,
      remoteFileId: prepared.remoteFileId,
      uploadSessionId: prepared.uploadSessionId,
      remotePath: prepared.remotePath ?? remotePath,
    );
  }

  bool _isDuplicateCommitCollision(ApiException error) {
    final normalizedCode = error.code.trim().toLowerCase();
    final normalizedMessage = error.message.toLowerCase();
    return normalizedCode == 'asset_commit_failed' &&
        (normalizedMessage.contains('assets_user_id_sha256_key') ||
            normalizedMessage.contains(
              'duplicate key value violates unique constraint',
            ));
  }

  bool _isDuplicateCommitError(Object error) {
    if (error is ApiException) {
      return _isDuplicateCommitCollision(error);
    }
    final message = error.toString().toLowerCase();
    return message.contains('assets_user_id_sha256_key') ||
        message.contains('duplicate key value violates unique constraint');
  }

  Future<String?> _resolveDuplicateAssetId({
    required JoblensBackendApiClient client,
    required PhotoAsset asset,
    required String remoteProjectId,
  }) async {
    final bulkCheck = await client.bulkCheckAssets(
      projectId: remoteProjectId,
      assets: [
        BulkCheckAssetInput(deviceAssetId: asset.id, sha256: asset.hash),
      ],
    );
    final result = bulkCheck.results.cast<BulkCheckResult?>().firstOrNull;
    final remoteAssetId = result?.assetId?.trim();
    if (result == null ||
        !result.isDuplicate ||
        remoteAssetId == null ||
        remoteAssetId.isEmpty) {
      return null;
    }
    return remoteAssetId;
  }

  Future<void> _markJobsDone(List<SyncJob> jobs) async {
    for (final job in jobs) {
      final latestJob = await _db.getSyncJobForAsset(
        assetId: job.assetId,
        provider: job.providerType,
      );
      if (latestJob == null) {
        continue;
      }
      await _db.updateSyncJob(
        latestJob.copyWith(
          state: SyncJobState.done,
          attemptCount: latestJob.attemptCount + 1,
          lastError: null,
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

Future<void> _forEachWithConcurrency<T>(
  List<T> items,
  int maxConcurrency,
  Future<void> Function(T item) action,
) async {
  if (items.isEmpty) {
    return;
  }

  final concurrency = maxConcurrency < 1 ? 1 : maxConcurrency;
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      if (nextIndex >= items.length) {
        return;
      }
      final item = items[nextIndex];
      nextIndex += 1;
      await action(item);
    }
  }

  await Future.wait(
    List.generate(
      concurrency > items.length ? items.length : concurrency,
      (_) => worker(),
    ),
  );
}
