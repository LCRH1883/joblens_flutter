import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
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
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  bool _isRunning = false;
  bool _runAgainRequested = false;
  bool _isRepairingRemoteProjection = false;
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
          'local_cloud_state_normalize_failed',
          () => _normalizeLocalAssetCloudStates(),
        );
        await _runVoidLaneSafely(
          'local_sync_backfill_failed',
          () => _backfillLocalSyncState(),
        );
        final pushedMetadata = await _runLaneSafely<bool>(
          'metadata_sync_failed',
          () => _pushMetadata(),
          fallback: false,
        );
        final advancedUploads = await _runLaneSafely<bool>(
          'blob_upload_sync_failed',
          () => _advanceBlobUploads(),
          fallback: false,
        );
        final pulledEvents = await _runLaneSafely<bool>(
          'remote_event_pull_failed',
          () => _pullRemoteEvents(),
          fallback: false,
        );
        await _runVoidLaneSafely(
          'local_asset_reconcile_failed',
          () => _reconcileCommittedAssetShadows(),
        );
        if (pushedMetadata.value ||
            advancedUploads.value ||
            pulledEvents.value) {
          _runAgainRequested = true;
        }
        if (pushedMetadata.succeeded &&
            advancedUploads.succeeded &&
            pulledEvents.succeeded) {
          await _recordSuccessfulSyncPass();
        }
      } while (_runAgainRequested);
    } finally {
      _isRunning = false;
    }
  }

  Future<_LaneResult<T>> _runLaneSafely<T>(
    String event,
    Future<T> Function() action, {
    required T fallback,
  }) async {
    try {
      return _LaneResult(value: await action(), succeeded: true);
    } catch (error) {
      final mapped = _mapSyncError(error);
      await _logError(event, message: mapped.message);
      return _LaneResult(value: fallback, succeeded: false);
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

  Future<void> _recordSuccessfulSyncPass() async {
    final client = _backendApiClient;
    if (client == null) {
      return;
    }
    final backendDeviceId = await _db.getBackendDeviceId();
    if (backendDeviceId == null || backendDeviceId.trim().isEmpty) {
      return;
    }
    await client.updateDeviceActivity(
      deviceId: backendDeviceId,
      lastSyncEventId: await _db.getLastSyncEventId(),
      markSyncAt: true,
    );
  }

  Future<void> _ensureDeviceRegistration() async {
    final existing = await _db.getBackendDeviceId();
    if (existing != null && existing.trim().isNotEmpty) {
      return;
    }
    await registerCurrentDevice();
  }

  Future<RegisterDeviceResponse> registerCurrentDevice() async {
    final client = _backendApiClient;
    if (client == null) {
      throw ApiException.authMissing();
    }

    final clientDeviceId = await _db.getOrCreateClientDeviceId();
    final deviceName = await _resolveDeviceName();
    final response = await client.registerDevice(
      clientDeviceId: clientDeviceId,
      platform: Platform.operatingSystem,
      deviceName: deviceName,
      osVersion: Platform.operatingSystemVersion,
    );
    await _db.setBackendDeviceId(response.deviceId);
    return response;
  }

  Future<String> _resolveDeviceName() async {
    try {
      if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        final preferred = [
          info.name,
          '${info.model} ${info.systemVersion}'.trim(),
          info.model,
          info.utsname.machine,
          'iPhone',
        ];
        return _pickDeviceName(preferred);
      }
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        final preferred = [
          [
            info.manufacturer,
            info.model,
          ].where((part) => part.trim().isNotEmpty).join(' ').trim(),
          info.model,
          info.device,
          'Android device',
        ];
        return _pickDeviceName(preferred);
      }
      if (Platform.isMacOS) {
        final info = await _deviceInfo.macOsInfo;
        final preferred = [info.computerName, info.model, 'Mac'];
        return _pickDeviceName(preferred);
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Device name lookup failed: $error');
      }
    }

    return _pickDeviceName([
      Platform.localHostname,
      Platform.operatingSystem,
      'Joblens device',
    ]);
  }

  String _pickDeviceName(Iterable<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        continue;
      }
      if (trimmed.toLowerCase() == 'localhost') {
        continue;
      }
      return trimmed;
    }
    return 'Joblens device';
  }

  Future<SignedInDevicesResponse> listSignedInDevices() async {
    final client = _backendApiClient;
    if (client == null) {
      throw ApiException.authMissing();
    }
    return client.listDevices();
  }

  Future<void> signOutDevice(String deviceId) async {
    final client = _backendApiClient;
    if (client == null) {
      throw ApiException.authMissing();
    }
    await client.signOutDevice(deviceId);
  }

  Future<SessionStatusResponse> getSessionStatus() async {
    final client = _backendApiClient;
    if (client == null) {
      throw ApiException.authMissing();
    }
    return client.getSessionStatus();
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
    String? activeConnectionId;
    for (final provider in providers) {
      if (provider.providerType == CloudProviderType.backend ||
          !provider.hasActiveConnection) {
        continue;
      }
      final connectionId = provider.connectionId?.trim();
      if (connectionId == null || connectionId.isEmpty) {
        continue;
      }
      activeConnectionId = connectionId;
      break;
    }
    if (activeConnectionId == null || activeConnectionId.isEmpty) {
      return;
    }
    final queued = await _db.backfillEligibleBlobUploads(
      activeProviderConnectionId: activeConnectionId,
    );
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
    final projects = await syncRemoteProjects(
      await _db.getProjects(includeDeleted: true),
    );
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
          assetId: record.entityType == SyncEntityType.asset
              ? record.entityId
              : null,
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
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
      return;
    }

    final project = await _db.getProjectById(projectId);
    if (project == null) {
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
      return;
    }

    if (project.deletedAt != null) {
      if (project.remoteProjectId != null &&
          project.remoteProjectId!.isNotEmpty) {
        await archiveProject(project.remoteProjectId!);
      }
      await _db.markProjectSynced(
        project.id,
        remoteProjectId: project.remoteProjectId,
        remoteRev: project.remoteRev,
      );
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
      return;
    }

    final remoteProjectId = await syncProject(project);
    if (remoteProjectId != null && remoteProjectId.isNotEmpty) {
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
    }
  }

  Future<void> _pushAssetRecord(EntitySyncRecord record) async {
    final asset = await _db.getAssetById(record.entityId);
    if (asset == null) {
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
      return;
    }

    if (asset.status == AssetStatus.deleted || asset.deletedAt != null) {
      final remoteAssetId = asset.remoteAssetId?.trim();
      if (remoteAssetId == null || remoteAssetId.isEmpty) {
        await _db.completeEntitySync(
          record.entityType,
          record.entityId,
          upToLocalSeq: record.localSeq,
        );
        return;
      }

      await deleteRemoteAsset(asset);
      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        cloudState: AssetCloudState.deleted,
        lastSyncErrorCode: null,
        dirtyFields: const [],
      );
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
      return;
    }

    final remoteAssetId = asset.remoteAssetId?.trim();
    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      await _db.completeEntitySync(
        record.entityType,
        record.entityId,
        upToLocalSeq: record.localSeq,
      );
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
    await _db.completeEntitySync(
      record.entityType,
      record.entityId,
      upToLocalSeq: record.localSeq,
    );
  }

  Future<bool> _advanceBlobUploads() async {
    final tasks = await _db.getPendingBlobUploadTasks();
    if (tasks.isEmpty) {
      return false;
    }

    await _forEachWithConcurrency(tasks, _maxParallelAssetOperations, (
      task,
    ) async {
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
    final hasCanonicalRemoteAsset =
        asset.remoteAssetId != null && asset.remoteAssetId!.trim().isNotEmpty;
    final activeProviderConnectionId = await _db
        .getActiveProviderConnectionId();
    final activeMirror = activeProviderConnectionId == null
        ? null
        : await _db.getAssetProviderMirrorSnapshot(
            assetId: asset.id,
            providerConnectionId: activeProviderConnectionId,
          );
    final needsActiveProviderUpload =
        hasCanonicalRemoteAsset &&
        activeProviderConnectionId != null &&
        (activeMirror != null &&
            (activeMirror.status == 'pending' ||
                (activeMirror.status == 'failed' &&
                    activeMirror.lastError == 'needs_client_upload')));
    if (hasCanonicalRemoteAsset && !needsActiveProviderUpload) {
      await _db.completeBlobUpload(task.assetId, task.uploadGeneration);
      await _db.completeEntitySync(
        SyncEntityType.asset,
        task.assetId,
        upToLocalSeq: asset.localSeq,
      );
      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        cloudState: AssetCloudState.localAndCloud,
        lastSyncErrorCode: null,
        dirtyFields: const [],
      );
      return;
    }

    await _db.markBlobUploadUploading(task.assetId, task.uploadGeneration);
    await _logInfo(
      'upload_started',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Started uploading asset to the active cloud provider.',
    );

    final remoteProjectId = await _ensureProjectRemoteId(asset.projectId);
    final context = _PendingAssetContext(asset: asset);
    try {
      if (!needsActiveProviderUpload) {
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
          await _db.completeEntitySync(
            SyncEntityType.asset,
            task.assetId,
            upToLocalSeq: asset.localSeq,
          );
          await _db.updateAssetCloudMetadata(
            assetId: asset.id,
            cloudState: AssetCloudState.localAndCloud,
            lastSyncErrorCode: null,
            dirtyFields: const [],
          );
          return;
        }
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
      await _db.completeEntitySync(
        SyncEntityType.asset,
        task.assetId,
        upToLocalSeq: asset.localSeq,
      );
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
        await _db.completeEntitySync(
          SyncEntityType.asset,
          task.assetId,
          upToLocalSeq: asset.localSeq,
        );
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
        await _db.setLastSyncEventId(event.id);
        after = event.id;
      }
      if (needsSnapshotRefresh) {
        final projects = await syncRemoteProjects(
          await _db.getProjects(includeDeleted: true),
        );
        await mergeRemoteAssets(projects);
      }

      await _runAssetIntegrityChecks();

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
      case 'asset_purge_requested':
      case 'asset_purged':
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
      connectionId: _payloadString(connectionPayload, [
        'connectionId',
        'connection_id',
      ]),
      connectedAt: _payloadDateTime(connectionPayload, [
        'connectedAt',
        'connected_at',
      ]),
      displayName: _payloadString(connectionPayload, [
        'displayName',
        'display_name',
      ]),
      accountIdentifier: _payloadString(connectionPayload, [
        'accountIdentifier',
        'account_identifier',
      ]),
      rootDisplayName: _payloadString(connectionPayload, [
        'rootDisplayName',
        'root_display_name',
      ]),
      rootFolderPath: _payloadString(connectionPayload, [
        'rootFolderPath',
        'root_folder_path',
      ]),
      lastError: _payloadString(connectionPayload, ['lastError', 'last_error']),
      isActive:
          _payloadBool(connectionPayload, ['isActive', 'is_active']) &&
          !_payloadBool(connectionPayload, ['deleted']),
      syncHealth:
          _payloadString(connectionPayload, ['syncHealth', 'sync_health']) ??
          'healthy',
      openConflictCount:
          _payloadInt(connectionPayload, [
            'openConflictCount',
            'open_conflict_count',
          ]) ??
          0,
    );
    return true;
  }

  Future<bool> _applyProjectProviderMirrorEvent(BackendSyncEvent event) async {
    final mirrorPayload = toObjectMap(event.payload['projectMirror']);
    if (mirrorPayload.isEmpty) {
      return false;
    }
    final remoteProjectId = _payloadString(mirrorPayload, [
      'projectId',
      'project_id',
    ])?.trim();
    final providerConnectionId = _payloadString(mirrorPayload, [
      'providerConnectionId',
      'provider_connection_id',
    ])?.trim();
    if (remoteProjectId == null ||
        remoteProjectId.isEmpty ||
        providerConnectionId == null ||
        providerConnectionId.isEmpty) {
      return false;
    }
    final localProjectId = await _db.getLocalProjectIdByRemoteId(
      remoteProjectId,
    );
    if (localProjectId == null) {
      return false;
    }
    await _db.upsertProjectProviderMirror(
      localProjectId: localProjectId,
      providerConnectionId: providerConnectionId,
      status: _payloadString(mirrorPayload, ['status']) ?? 'pending',
      providerFolderId: _payloadString(mirrorPayload, [
        'providerFolderId',
        'provider_folder_id',
      ]),
      providerRev: _payloadString(mirrorPayload, [
        'providerRev',
        'provider_rev',
      ]),
      lastError: _payloadString(mirrorPayload, ['lastError', 'last_error']),
    );
    return true;
  }

  Future<bool> _applyAssetProviderMirrorEvent(BackendSyncEvent event) async {
    final mirrorPayload = toObjectMap(event.payload['assetMirror']);
    if (mirrorPayload.isEmpty) {
      return false;
    }
    final remoteAssetId = _payloadString(mirrorPayload, [
      'assetId',
      'asset_id',
    ])?.trim();
    final providerConnectionId = _payloadString(mirrorPayload, [
      'providerConnectionId',
      'provider_connection_id',
    ])?.trim();
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
      providerFileId: _payloadString(mirrorPayload, [
        'providerFileId',
        'provider_file_id',
      ]),
      remotePath: _payloadString(mirrorPayload, ['remotePath', 'remote_path']),
      providerRev: _payloadString(mirrorPayload, [
        'providerRev',
        'provider_rev',
      ]),
      lastError: _payloadString(mirrorPayload, ['lastError', 'last_error']),
    );
    return true;
  }

  Future<bool> _applyRemoteProjectEvent(BackendSyncEvent event) async {
    final projectPayload = toObjectMap(event.payload['project']);
    if (projectPayload.isEmpty) {
      return false;
    }

    final remoteProjectId = _payloadString(projectPayload, [
      'projectId',
      'id',
    ])?.trim();
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
    if (event.eventType == 'asset_purged') {
      final localAssets = await _db.getAssetsByRemoteId(event.entityId);
      if (localAssets.isEmpty) {
        return true;
      }
      await _db.purgeAssetsByIds(localAssets.map((asset) => asset.id));
      await _logInfo(
        'remote_asset_purged',
        assetId: localAssets.first.id,
        projectId: localAssets.first.projectId,
        message: 'Removed purged asset from the local library projection.',
      );
      return true;
    }

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
      allowResurrection: event.eventType == 'asset_restored',
    );
    return true;
  }

  String _cloudStateForRemoteAsset(
    BackendAssetRecord remoteAsset, {
    required bool hasLocalPath,
  }) {
    return AssetPresence.canonicalCloudState(
      deleted: remoteAsset.deleted,
      hasLocalOriginal: hasLocalPath,
      hasConfirmedCloudSource: _remoteAssetHasConfirmedCloudSource(remoteAsset),
    );
  }

  bool _remoteAssetHasConfirmedCloudSource(BackendAssetRecord remoteAsset) {
    if (remoteAsset.deleted) {
      return false;
    }
    if (remoteAsset.cloudAvailable != null) {
      return remoteAsset.cloudAvailable!;
    }
    switch (remoteAsset.storageState?.trim()) {
      case AssetCloudState.localAndCloud:
      case AssetCloudState.cloudOnly:
        return true;
    }
    return AssetPresence.hasConfirmedRemoteFileSource(
      remoteFileId: remoteAsset.remoteFileId,
      remotePath: remoteAsset.remotePath,
    );
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
    for (final task in uploads.where(
      (item) => item.state == BlobUploadState.failed,
    )) {
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
            'expired' =>
              ProviderConnectionStatus.reconnectRequired.storageValue,
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
        syncHealth: connection.syncHealth,
        openConflictCount: connection.openConflictCount,
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
              'completed' =>
                ProviderConnectionStatus.connectedBootstrapping.storageValue,
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
      syncHealth: 'healthy',
      openConflictCount: 0,
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
      syncHealth: 'healthy',
      openConflictCount: 0,
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
        .where(
          (project) => (project.remoteProjectId?.trim().isNotEmpty ?? false),
        )
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
          name: remoteProject.name.trim().isEmpty
              ? 'Inbox'
              : remoteProject.name.trim(),
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

    await _runAssetIntegrityChecks();
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

  Future<Uint8List> downloadAssetBytes(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId?.trim() ?? '';
    final client = _backendApiClient;
    if (client == null || remoteAssetId.isEmpty) {
      throw const ApiException(
        code: 'remote_download_unavailable',
        message: 'This asset is not available for remote download.',
      );
    }
    return client.downloadAssetBytes(remoteAssetId);
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

    await client.deleteAsset(remoteAssetId, expectedRevision: asset.remoteRev);
    await _logInfo(
      'remote_delete_requested',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Requested remote delete for synced asset.',
    );
    await invalidateThumbnailUrl(asset);
    await invalidateDownloadUrl(asset);
  }

  Future<void> restoreAsset(PhotoAsset asset) async {
    final client = _backendApiClient;
    final remoteAssetId = asset.remoteAssetId?.trim();
    final hasLocalFile = await _assetHasLocalFile(asset);
    if (client == null) {
      await _db.restoreAsset(asset.id);
      return;
    }

    if (remoteAssetId == null || remoteAssetId.isEmpty) {
      final remoteMatch = await _findRemoteRestoreCandidate(asset);
      if (remoteMatch != null) {
        final resolved = remoteMatch.deleted
            ? await client.restoreAsset(
                remoteMatch.assetId,
                expectedRevision: remoteMatch.revision,
                hasLocalFile: hasLocalFile,
              )
            : remoteMatch;
        await _mergeRemoteAsset(
          resolved,
          fallbackLocalProjectId: asset.projectId,
          allowResurrection: true,
        );
        final canonical = await _db.getAssetByRemoteId(resolved.assetId);
        if (canonical != null &&
            canonical.localPath.trim().isEmpty &&
            asset.localPath.trim().isNotEmpty &&
            await File(asset.localPath).exists()) {
          await _db.updateAssetLocalMedia(
            assetId: canonical.id,
            localPath: asset.localPath,
            thumbPath: asset.thumbPath,
            hash: asset.hash,
            cloudState: AssetPresence.canonicalCloudState(
              deleted: false,
              hasLocalOriginal: true,
              hasConfirmedCloudSource: _remoteAssetHasConfirmedCloudSource(
                resolved,
              ),
            ),
            existsInPhoneStorage: asset.existsInPhoneStorage,
          );
        }
        if (canonical != null && canonical.id != asset.id) {
          await _db.purgeAsset(asset.id);
        }
        await _logInfo(
          'remote_restore_shadow_resolved',
          assetId: asset.id,
          projectId: asset.projectId,
          message:
              'Resolved restore against canonical remote asset '
              '${remoteMatch.assetId}.',
        );
        return;
      }

      await _db.restoreAsset(asset.id);
      return;
    }

    final restored = await client.restoreAsset(
      remoteAssetId,
      expectedRevision: asset.remoteRev,
      hasLocalFile: hasLocalFile,
    );
    await _mergeRemoteAsset(
      restored,
      fallbackLocalProjectId: asset.projectId,
      allowResurrection: true,
    );
    await _logInfo(
      'remote_restore_completed',
      assetId: asset.id,
      projectId: asset.projectId,
      message: 'Restored asset from Trash.',
    );
  }

  Future<bool> _assetHasLocalFile(PhotoAsset asset) async {
    final path = asset.localPath.trim();
    if (path.isEmpty) {
      return false;
    }
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  Future<BackendAssetRecord?> _findRemoteRestoreCandidate(
    PhotoAsset asset,
  ) async {
    final client = _backendApiClient;
    if (client == null) {
      return null;
    }
    final hash = asset.hash.trim();
    if (hash.length != 64) {
      return null;
    }
    final project = await _db.getProjectById(asset.projectId);
    final remoteProjectId = project?.remoteProjectId?.trim();
    if (remoteProjectId == null || remoteProjectId.isEmpty) {
      return null;
    }

    final matches = <BackendAssetRecord>[];
    String? cursor;
    do {
      final response = await client.listAssets(
        ListAssetsRequest(
          projectId: remoteProjectId,
          includeDeleted: true,
          cursor: cursor,
          limit: 200,
        ),
      );
      matches.addAll(
        response.assets.where((candidate) => candidate.sha256 == hash),
      );
      cursor = response.nextCursor;
    } while (cursor != null && cursor.isNotEmpty && matches.length <= 1);

    if (matches.length != 1) {
      if (matches.length > 1) {
        await _logInfo(
          'remote_restore_candidate_ambiguous',
          assetId: asset.id,
          projectId: asset.projectId,
          message:
              'Skipped remote restore reconciliation because ${matches.length} '
              'remote assets matched the same hash in this project.',
        );
      }
      return null;
    }
    return matches.single;
  }

  Future<void> purgeAsset(PhotoAsset asset) async {
    final client = _backendApiClient;
    final remoteAssetId = asset.remoteAssetId?.trim();
    if (client == null || remoteAssetId == null || remoteAssetId.isEmpty) {
      await _db.purgeAsset(asset.id);
      return;
    }

    await _db.markAssetPurgeRequested(asset.id);
    try {
      await client.purgeAsset(remoteAssetId, expectedRevision: asset.remoteRev);
      await _logInfo(
        'remote_purge_requested',
        assetId: asset.id,
        projectId: asset.projectId,
        message: 'Queued permanent delete for the trashed asset.',
      );
    } catch (_) {
      await _db.clearAssetPurgeRequested(asset.id);
      rethrow;
    }
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

  Future<void> _runAssetIntegrityChecks() async {
    if (_isRepairingRemoteProjection) {
      return;
    }
    final issues = await _db.scanAssetIntegrityIssues();
    if (issues.isEmpty) {
      return;
    }

    for (final issue in issues) {
      await _logError(
        'asset_integrity_issue',
        message:
            'Detected ${issue.kind.name} for ${issue.value} '
            '(count=${issue.count}).',
      );
    }

    final shouldRepair = issues.any(
      (issue) =>
          issue.kind == AssetIntegrityIssueKind.duplicateRemoteAssetId ||
          issue.kind == AssetIntegrityIssueKind.duplicateRemoteHash,
    );
    if (!shouldRepair) {
      return;
    }

    final projects = await _db.getProjects(includeDeleted: true);
    await _repairRemoteProjection(projects);
  }

  Future<void> _repairRemoteProjection(List<Project> projects) async {
    if (_isRepairingRemoteProjection) {
      return;
    }
    _isRepairingRemoteProjection = true;
    try {
      final remoteLinkedAssets = await _db.getRemoteLinkedAssets(
        includeDeleted: true,
      );
      if (remoteLinkedAssets.isEmpty) {
        return;
      }

      final preservedLocalMedia = <String, PhotoAsset>{};
      for (final asset in remoteLinkedAssets) {
        final remoteAssetId = asset.remoteAssetId?.trim();
        if (remoteAssetId == null ||
            remoteAssetId.isEmpty ||
            asset.localPath.trim().isEmpty) {
          continue;
        }
        final existing = preservedLocalMedia[remoteAssetId];
        if (existing == null || existing.localPath.trim().isEmpty) {
          preservedLocalMedia[remoteAssetId] = asset;
        }
      }

      await _db.purgeAssetsByIds(remoteLinkedAssets.map((asset) => asset.id));
      await _logInfo(
        'remote_projection_repair_started',
        message:
            'Rebuilding remote asset projection for ${remoteLinkedAssets.length} local rows.',
      );
      await mergeRemoteAssets(projects);

      for (final entry in preservedLocalMedia.entries) {
        final rebuilt = await _db.getAssetByRemoteId(entry.key);
        final preserved = entry.value;
        if (rebuilt == null || rebuilt.localPath.trim().isNotEmpty) {
          continue;
        }
        if (!await File(preserved.localPath).exists()) {
          continue;
        }
        await _db.updateAssetLocalMedia(
          assetId: rebuilt.id,
          localPath: preserved.localPath,
          thumbPath: preserved.thumbPath,
          hash: preserved.hash,
          cloudState: rebuilt.status == AssetStatus.deleted
              ? AssetCloudState.deleted
              : AssetCloudState.localAndCloud,
          existsInPhoneStorage: preserved.existsInPhoneStorage,
        );
      }

      await _reconcileCommittedAssetShadows();

      await _logInfo(
        'remote_projection_repair_completed',
        message: 'Remote asset projection repair completed.',
      );
    } finally {
      _isRepairingRemoteProjection = false;
    }
  }

  Future<void> _mergeRemoteAsset(
    BackendAssetRecord remoteAsset, {
    required int fallbackLocalProjectId,
    bool allowResurrection = false,
  }) async {
    final localProjectId = remoteAsset.projectId == null
        ? fallbackLocalProjectId
        : await _db.getLocalProjectIdByRemoteId(remoteAsset.projectId!) ??
              fallbackLocalProjectId;

    final matchingRemoteAssets = await _db.getAssetsByRemoteId(
      remoteAsset.assetId,
    );
    if (matchingRemoteAssets.length > 1) {
      await _logError(
        'remote_asset_duplicate_remote_id',
        assetId: matchingRemoteAssets.first.id,
        projectId: matchingRemoteAssets.first.projectId,
        message:
            'Detected ${matchingRemoteAssets.length} local rows for remote asset '
            '${remoteAsset.assetId}. Triggering projection repair.',
      );
      await _repairRemoteProjection(
        await _db.getProjects(includeDeleted: true),
      );
      final repairedAssets = await _db.getAssetsByRemoteId(remoteAsset.assetId);
      if (repairedAssets.length > 1) {
        return;
      }
    }
    final existingByRemote = (await _db.getAssetsByRemoteId(
      remoteAsset.assetId,
    )).firstOrNull;

    if (existingByRemote != null) {
      if (existingByRemote.status == AssetStatus.deleted &&
          !remoteAsset.deleted &&
          !allowResurrection) {
        await _db.updateAssetCloudMetadata(
          assetId: existingByRemote.id,
          remoteAssetId: remoteAsset.assetId,
          remoteProvider: remoteAsset.provider?.key,
          remoteFileId: remoteAsset.remoteFileId,
          uploadPath: remoteAsset.remotePath,
          cloudState: AssetCloudState.deleted,
        );
        await _logInfo(
          'remote_delete_preserved',
          assetId: existingByRemote.id,
          projectId: existingByRemote.projectId,
          message:
              'Preserved local deletion while waiting for backend/cloud delete to converge.',
        );
        return;
      }

      final cloudState = _cloudStateForRemoteAsset(
        remoteAsset,
        hasLocalPath: existingByRemote.localPath.isNotEmpty,
      );
      await _db.applyRemoteAssetSnapshot(
        localAssetId: existingByRemote.id,
        projectId: localProjectId,
        remoteAssetId: remoteAsset.assetId,
        sha256: remoteAsset.sha256,
        createdAt:
            remoteAsset.takenAt ?? remoteAsset.createdAt ?? DateTime.now(),
        remoteRev: remoteAsset.revision,
        filename: remoteAsset.filename,
        remoteProvider: remoteAsset.provider?.key,
        remoteFileId: remoteAsset.remoteFileId,
        remotePath: remoteAsset.remotePath,
        softDeletedAt: remoteAsset.softDeletedAt,
        hardDeleteDueAt: remoteAsset.hardDeleteDueAt,
        purgeRequestedAt: remoteAsset.purgeRequestedAt,
        cloudState: cloudState,
        deleted: remoteAsset.deleted,
      );
      await _reconcileCommittedAssetShadow(
        remoteAssetId: remoteAsset.assetId,
        sha256: remoteAsset.sha256,
        localProjectId: localProjectId,
      );
      final reconciledAsset = await _db.getAssetByRemoteId(remoteAsset.assetId);
      if (!remoteAsset.deleted &&
          (reconciledAsset?.localPath.trim().isEmpty ??
              existingByRemote.localPath.isEmpty)) {
        await _downloadRemoteAssetLocally(
          (reconciledAsset ?? existingByRemote).copyWith(
            projectId: localProjectId,
            cloudState: cloudState,
            remoteAssetId: remoteAsset.assetId,
            remoteProvider: remoteAsset.provider?.key,
            remoteFileId: remoteAsset.remoteFileId,
            uploadPath: remoteAsset.remotePath,
            lastSyncErrorCode: null,
            deletedAt: null,
            hardDeleteDueAt: null,
          ),
          remoteAsset: remoteAsset,
        );
      }
      return;
    }

    final hashCandidates = await _db.getAssetsByHashValue(remoteAsset.sha256);
    final unlinkedHashCandidates = hashCandidates
        .where((asset) {
          final remoteId = asset.remoteAssetId?.trim() ?? '';
          return remoteId.isEmpty &&
              asset.uploadSessionId != null &&
              asset.uploadSessionId!.trim().isNotEmpty;
        })
        .toList(growable: false);
    if (unlinkedHashCandidates.isNotEmpty) {
      await _logInfo(
        'remote_asset_hash_binding_rejected',
        assetId: unlinkedHashCandidates.first.id,
        projectId: unlinkedHashCandidates.first.projectId,
        message:
            'Skipped uncorrelated same-hash remote merge for ${remoteAsset.assetId}; '
            'strict remote identity is now required.',
      );
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
      softDeletedAt: remoteAsset.softDeletedAt,
      hardDeleteDueAt: remoteAsset.hardDeleteDueAt,
      purgeRequestedAt: remoteAsset.purgeRequestedAt,
      cloudState: _cloudStateForRemoteAsset(remoteAsset, hasLocalPath: false),
      deleted: remoteAsset.deleted,
    );
    await _reconcileCommittedAssetShadow(
      remoteAssetId: remoteAsset.assetId,
      sha256: remoteAsset.sha256,
      localProjectId: localProjectId,
    );
    if (!remoteAsset.deleted) {
      final localAsset = await _db.getAssetByRemoteId(remoteAsset.assetId);
      if (localAsset != null) {
        await _downloadRemoteAssetLocally(localAsset, remoteAsset: remoteAsset);
      }
    }
  }

  Future<void> _reconcileCommittedAssetShadows() async {
    final remoteLinkedAssets = await _db.getRemoteLinkedAssets(
      includeDeleted: false,
    );
    for (final asset in remoteLinkedAssets) {
      final remoteAssetId = asset.remoteAssetId?.trim();
      if (remoteAssetId == null || remoteAssetId.isEmpty) {
        continue;
      }
      if (asset.status == AssetStatus.deleted || asset.deletedAt != null) {
        continue;
      }
      if (asset.hash.length != 64) {
        continue;
      }
      await _reconcileCommittedAssetShadow(
        remoteAssetId: remoteAssetId,
        sha256: asset.hash,
        localProjectId: asset.projectId,
      );
    }
  }

  Future<void> _normalizeLocalAssetCloudStates() async {
    final assets = await _db.getRemoteLinkedAssets(includeDeleted: false);
    if (assets.isEmpty) {
      return;
    }

    final activeConnectionId = await _db.getActiveProviderConnectionId();
    final mirrorStatuses =
        activeConnectionId == null || activeConnectionId.trim().isEmpty
        ? const <String, String>{}
        : await _db.getAssetProviderMirrorStatuses(
            assetIds: assets.map((asset) => asset.id),
            providerConnectionId: activeConnectionId,
          );

    for (final asset in assets) {
      if (asset.cloudState != AssetCloudState.localOnly ||
          asset.localPath.trim().isEmpty) {
        continue;
      }

      final normalizedCloudState = AssetPresence.canonicalCloudState(
        deleted: false,
        hasLocalOriginal: true,
        hasConfirmedCloudSource: AssetPresence.hasConfirmedCloudSource(
          asset,
          mirrorStatus: mirrorStatuses[asset.id],
        ),
      );
      if (normalizedCloudState != AssetCloudState.localAndCloud) {
        continue;
      }

      await _db.updateAssetCloudMetadata(
        assetId: asset.id,
        cloudState: normalizedCloudState,
        lastSyncErrorCode: asset.lastSyncErrorCode,
      );
    }
  }

  Future<void> _reconcileCommittedAssetShadow({
    required String remoteAssetId,
    required String sha256,
    required int localProjectId,
  }) async {
    final canonical = await _db.getAssetByRemoteId(remoteAssetId);
    if (canonical == null ||
        canonical.status == AssetStatus.deleted ||
        canonical.deletedAt != null) {
      return;
    }

    final duplicates = (await _db.getAssetsByHashValue(sha256))
        .where((asset) {
          if (asset.id == canonical.id) {
            return false;
          }
          if (asset.projectId != localProjectId) {
            return false;
          }
          if (asset.status == AssetStatus.deleted || asset.deletedAt != null) {
            return false;
          }
          final candidateRemoteId = asset.remoteAssetId?.trim() ?? '';
          return candidateRemoteId.isEmpty;
        })
        .toList(growable: false);
    if (duplicates.isEmpty) {
      return;
    }

    var preservedMedia = false;
    if (canonical.localPath.trim().isEmpty) {
      final localMediaSource = duplicates.firstWhere(
        (asset) => asset.localPath.trim().isNotEmpty,
        orElse: () => canonical,
      );
      if (localMediaSource.id != canonical.id &&
          localMediaSource.localPath.trim().isNotEmpty) {
        await _db.updateAssetLocalMedia(
          assetId: canonical.id,
          localPath: localMediaSource.localPath,
          thumbPath: localMediaSource.thumbPath,
          hash: localMediaSource.hash,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: localMediaSource.existsInPhoneStorage,
        );
        preservedMedia = true;
      }
    }

    await _db.purgeAssetsByIds(duplicates.map((asset) => asset.id));
    await _logInfo(
      'remote_asset_shadow_reconciled',
      assetId: canonical.id,
      projectId: canonical.projectId,
      message:
          'Removed ${duplicates.length} stale local upload '
          'shadow${duplicates.length == 1 ? '' : 's'} for remote asset '
          '$remoteAssetId.${preservedMedia ? ' Preserved local media.' : ''}',
    );
  }

  Future<void> _downloadRemoteAssetLocally(
    PhotoAsset asset, {
    required BackendAssetRecord remoteAsset,
  }) async {
    asset;
    remoteAsset;
    _mediaStorage;
    // Normal sync no longer auto-downloads full originals. Thumbnails and
    // download URLs are resolved on demand from the active provider.
    return;
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

      if (prepared.provider == CloudProviderType.oneDrive) {
        await _logInfo(
          'onedrive_upload_session_created',
          assetId: context.asset.id,
          projectId: context.asset.projectId,
          message:
              'OneDrive upload session ready '
              '(uploadSessionId=${prepared.uploadSessionId ?? '-'}, '
              'remotePath=$remotePath).',
        );
      }

      final uploadResult = await client.uploadWithInstruction(
        instruction: instruction,
        bytes: bytes,
        contentType: mimeType,
        filename: filename,
      );
      final committedRemoteFileId =
          uploadResult.remoteFileId ?? prepared.remoteFileId;

      if (prepared.provider == CloudProviderType.oneDrive) {
        await _logInfo(
          'onedrive_upload_completed',
          assetId: context.asset.id,
          projectId: context.asset.projectId,
          message:
              'OneDrive upload completed '
              '(remoteFileId=${committedRemoteFileId ?? '-'}, '
              'response=${uploadResult.rawResponse == null ? '{}' : jsonEncode(uploadResult.rawResponse)}).',
        );
        await _logInfo(
          'onedrive_commit_payload',
          assetId: context.asset.id,
          projectId: context.asset.projectId,
          message:
              'Committing OneDrive asset with '
              'uploadSessionId=${prepared.uploadSessionId ?? '-'}, '
              'remoteFileId=${committedRemoteFileId ?? '-'}, '
              'remotePath=$remotePath.',
        );
      }

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
            remoteFileId: committedRemoteFileId,
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

class _LaneResult<T> {
  const _LaneResult({required this.value, required this.succeeded});

  final T value;
  final bool succeeded;
}

class _PendingAssetContext {
  const _PendingAssetContext({required this.asset});

  final PhotoAsset asset;
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
