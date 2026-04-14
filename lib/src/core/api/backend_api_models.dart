import '../models/cloud_provider.dart';

class ProviderConnectionSummary {
  const ProviderConnectionSummary({
    required this.provider,
    required this.status,
    this.connectionId,
    this.connectedAt,
    this.lastSyncAt,
    this.lastError,
    this.displayName,
    this.accountIdentifier,
    this.rootDisplayName,
    this.rootFolderPath,
    this.isActive = false,
    this.syncHealth = 'healthy',
    this.openConflictCount = 0,
  });

  final CloudProviderType provider;
  final String status;
  final String? connectionId;
  final DateTime? connectedAt;
  final DateTime? lastSyncAt;
  final String? lastError;
  final String? displayName;
  final String? accountIdentifier;
  final String? rootDisplayName;
  final String? rootFolderPath;
  final bool isActive;
  final String syncHealth;
  final int openConflictCount;

  bool get isConnected => status == 'ready' || status == 'connected';
  bool get isExpired => status == 'expired' || status == 'reconnect_required';

  factory ProviderConnectionSummary.fromMap(Map<String, dynamic> map) {
    return ProviderConnectionSummary(
      provider: CloudProviderTypeX.fromKey(
        _asString(map['provider'] ?? map['providerType']),
      ),
      status: _asString(map['status'], fallback: 'disconnected'),
      connectionId: _asNullableString(
        map['connectionId'] ?? map['connection_id'],
      ),
      connectedAt: _asNullableDateTime(
        map['connectedAt'] ?? map['connected_at'],
      ),
      lastSyncAt: _asNullableDateTime(map['lastSyncAt'] ?? map['last_sync_at']),
      lastError: _asNullableString(map['lastError'] ?? map['last_error']),
      displayName: _asNullableString(map['displayName'] ?? map['display_name']),
      accountIdentifier: _asNullableString(
        map['accountIdentifier'] ?? map['account_identifier'],
      ),
      rootDisplayName: _asNullableString(
        map['rootDisplayName'] ?? map['root_display_name'],
      ),
      rootFolderPath: _asNullableString(
        map['rootFolderPath'] ?? map['root_folder_path'],
      ),
      isActive: _asBool(map['isActive'] ?? map['is_active']),
      syncHealth:
          _asNullableString(map['syncHealth'] ?? map['sync_health']) ??
          'healthy',
      openConflictCount: _asInt(
        map['openConflictCount'] ?? map['open_conflict_count'],
      ),
    );
  }
}

class ProviderConnectionsResponse {
  const ProviderConnectionsResponse({required this.connections});

  final List<ProviderConnectionSummary> connections;

  factory ProviderConnectionsResponse.fromMap(Map<String, dynamic> map) {
    final raw = _asList(map['connections'] ?? map['providers']);
    return ProviderConnectionsResponse(
      connections: _asMapList(
        raw,
      ).map(ProviderConnectionSummary.fromMap).toList(growable: false),
    );
  }
}

class BeginProviderConnectionResponse {
  const BeginProviderConnectionResponse({
    required this.authorizationUrl,
    this.sessionId,
    this.expiresAt,
  });

  final String authorizationUrl;
  final String? sessionId;
  final DateTime? expiresAt;

  factory BeginProviderConnectionResponse.fromMap(Map<String, dynamic> map) {
    return BeginProviderConnectionResponse(
      authorizationUrl: _asString(
        map['launchUrl'] ??
            map['authorizationUrl'] ??
            map['authUrl'] ??
            map['url'],
      ),
      sessionId: _asNullableString(map['sessionId'] ?? map['state']),
      expiresAt: _asNullableDateTime(map['expiresAt'] ?? map['expires_at']),
    );
  }
}

class ProviderAuthSessionResult {
  const ProviderAuthSessionResult({
    required this.sessionId,
    required this.status,
    required this.provider,
    this.intent,
    this.connectionId,
    this.connectionStatus,
    this.providerAccountEmail,
    this.displayName,
    this.rootDisplayName,
    this.rootFolderPath,
    this.lastError,
    this.projectsPending = 0,
    this.assetsPending = 0,
  });

  final String sessionId;
  final String status;
  final CloudProviderType provider;
  final String? intent;
  final String? connectionId;
  final String? connectionStatus;
  final String? providerAccountEmail;
  final String? displayName;
  final String? rootDisplayName;
  final String? rootFolderPath;
  final String? lastError;
  final int projectsPending;
  final int assetsPending;

  bool get isCompleted => status == 'completed';

  factory ProviderAuthSessionResult.fromMap(Map<String, dynamic> map) {
    final bootstrapCounts = _asMap(
      map['bootstrapCounts'] ?? map['bootstrap_counts'],
    );
    return ProviderAuthSessionResult(
      sessionId: _asString(map['sessionId'] ?? map['sid'] ?? map['state']),
      status: _asString(map['status'], fallback: 'failed'),
      provider: CloudProviderTypeX.fromKey(_asString(map['provider'])),
      intent: _asNullableString(map['intent']),
      connectionId: _asNullableString(
        map['connectionId'] ?? map['connection_id'],
      ),
      connectionStatus: _asNullableString(
        map['connectionStatus'] ?? map['connection_status'],
      ),
      providerAccountEmail: _asNullableString(
        map['providerAccountEmail'] ??
            map['provider_account_email'] ??
            map['accountIdentifier'] ??
            map['account_identifier'],
      ),
      displayName: _asNullableString(map['displayName'] ?? map['display_name']),
      rootDisplayName: _asNullableString(
        map['rootDisplayName'] ?? map['root_display_name'],
      ),
      rootFolderPath: _asNullableString(
        map['rootFolderPath'] ?? map['root_folder_path'],
      ),
      lastError: _asNullableString(map['lastError'] ?? map['last_error']),
      projectsPending:
          _asNullableInt(
            bootstrapCounts['projectsPending'] ??
                bootstrapCounts['projects_pending'],
          ) ??
          0,
      assetsPending:
          _asNullableInt(
            bootstrapCounts['assetsPending'] ??
                bootstrapCounts['assets_pending'],
          ) ??
          0,
    );
  }
}

class RegisterDeviceResponse {
  const RegisterDeviceResponse({
    required this.deviceId,
    required this.isCurrent,
    this.deviceSessionId,
  });

  final String deviceId;
  final bool isCurrent;
  final String? deviceSessionId;

  factory RegisterDeviceResponse.fromMap(Map<String, dynamic> map) {
    final rawDevice = map['device'];
    final device = rawDevice is Map<String, dynamic>
        ? rawDevice
        : rawDevice is Map
        ? rawDevice.map((key, value) => MapEntry('$key', value))
        : map;
    return RegisterDeviceResponse(
      deviceId: _asString(device['id'] ?? map['deviceId']),
      isCurrent: _asBool(map['isCurrent'] ?? true),
      deviceSessionId: _asNullableString(
        map['deviceSessionId'] ?? map['device_session_id'],
      ),
    );
  }
}

class ApproxLocation {
  const ApproxLocation({
    this.city,
    this.region,
    this.countryCode,
    this.display,
  });

  final String? city;
  final String? region;
  final String? countryCode;
  final String? display;

  factory ApproxLocation.fromMap(Map<String, dynamic> map) {
    return ApproxLocation(
      city: _asNullableString(map['city']),
      region: _asNullableString(map['region']),
      countryCode: _asNullableString(map['countryCode'] ?? map['country_code']),
      display: _asNullableString(map['display']),
    );
  }
}

class SignedInDevice {
  const SignedInDevice({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.signedInAt,
    required this.lastSeenAt,
    required this.lastSyncAt,
    required this.isCurrent,
    required this.canSignOut,
    this.status = 'active',
    this.osVersion,
    this.appVersion,
    this.approxLocation,
    this.revokedAt,
    this.revokeReason,
    this.endedAt,
    this.endReason,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String status;
  final String? osVersion;
  final String? appVersion;
  final ApproxLocation? approxLocation;
  final DateTime? signedInAt;
  final DateTime? lastSeenAt;
  final DateTime? lastSyncAt;
  final DateTime? revokedAt;
  final String? revokeReason;
  final DateTime? endedAt;
  final String? endReason;
  final bool isCurrent;
  final bool canSignOut;

  bool get isActive => status == 'active';

  factory SignedInDevice.fromMap(Map<String, dynamic> map) {
    final location = _asMap(map['approxLocation'] ?? map['approx_location']);
    return SignedInDevice(
      deviceId: _asString(map['deviceId'] ?? map['device_id']),
      deviceName: _asString(map['deviceName'] ?? map['device_name']),
      platform: _asString(map['platform'], fallback: 'unknown'),
      status: _asString(map['status'], fallback: 'unknown'),
      osVersion: _asNullableString(map['osVersion'] ?? map['os_version']),
      appVersion: _asNullableString(map['appVersion'] ?? map['app_version']),
      approxLocation: location.isEmpty
          ? null
          : ApproxLocation.fromMap(location),
      signedInAt: _asNullableDateTime(map['signedInAt'] ?? map['signed_in_at']),
      lastSeenAt: _asNullableDateTime(map['lastSeenAt'] ?? map['last_seen_at']),
      lastSyncAt: _asNullableDateTime(map['lastSyncAt'] ?? map['last_sync_at']),
      revokedAt: _asNullableDateTime(map['revokedAt'] ?? map['revoked_at']),
      revokeReason: _asNullableString(map['revokeReason'] ?? map['revoke_reason']),
      endedAt: _asNullableDateTime(map['endedAt'] ?? map['ended_at']),
      endReason: _asNullableString(map['endReason'] ?? map['end_reason']),
      isCurrent: _asBool(map['isCurrent'] ?? map['is_current']),
      canSignOut: _asBool(map['canSignOut'] ?? map['can_sign_out']),
    );
  }
}

class SignedInDevicesResponse {
  const SignedInDevicesResponse({required this.devices});

  final List<SignedInDevice> devices;

  factory SignedInDevicesResponse.fromMap(Map<String, dynamic> map) {
    final raw = _asList(map['devices']);
    return SignedInDevicesResponse(
      devices: _asMapList(
        raw,
      ).map(SignedInDevice.fromMap).toList(growable: false),
    );
  }
}

class SessionStatusResponse {
  const SessionStatusResponse({
    required this.status,
    this.reason,
    this.message,
    this.registrationRequired = false,
  });

  final String status;
  final String? reason;
  final String? message;
  final bool registrationRequired;

  bool get isActive => status == 'active';
  bool get isRevoked => status == 'revoked';

  factory SessionStatusResponse.fromMap(Map<String, dynamic> map) {
    return SessionStatusResponse(
      status: _asString(map['status'], fallback: 'active'),
      reason: _asNullableString(map['reason']),
      message: _asNullableString(map['message']),
      registrationRequired: _asBool(
        map['registrationRequired'] ?? map['registration_required'],
      ),
    );
  }
}

class NextcloudConnectionRequest {
  const NextcloudConnectionRequest({
    required this.serverUrl,
    required this.username,
    required this.appPassword,
  });

  final String serverUrl;
  final String username;
  final String appPassword;

  Map<String, Object?> toMap() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'appPassword': appPassword,
    };
  }
}

class RemoteProjectUpsertRequest {
  const RemoteProjectUpsertRequest({
    required this.localProjectId,
    required this.name,
    this.remoteProjectId,
    this.expectedRevision,
  });

  final int localProjectId;
  final String name;
  final String? remoteProjectId;
  final int? expectedRevision;

  Map<String, Object?> toMap() {
    return {
      'localProjectId': localProjectId,
      'name': name,
      if (remoteProjectId != null && remoteProjectId!.isNotEmpty)
        'projectId': remoteProjectId,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    };
  }
}

class RemoteProjectRecord {
  const RemoteProjectRecord({
    required this.projectId,
    required this.name,
    this.revision,
    this.deleted = false,
  });

  final String projectId;
  final String name;
  final int? revision;
  final bool deleted;

  factory RemoteProjectRecord.fromMap(Map<String, dynamic> map) {
    return RemoteProjectRecord(
      projectId: _asString(map['projectId'] ?? map['id']),
      name: _asString(map['name']),
      revision:
          _asNullableInt(map['revision']) ?? _asNullableInt(map['remote_rev']),
      deleted:
          _asBool(map['deleted']) ||
          _asNullableString(map['status']) == 'deleted',
    );
  }
}

class ListProjectsResponse {
  const ListProjectsResponse({required this.projects});

  final List<RemoteProjectRecord> projects;

  factory ListProjectsResponse.fromMap(Map<String, dynamic> map) {
    final raw = _asList(map['projects']);
    return ListProjectsResponse(
      projects: _asMapList(
        raw,
      ).map(RemoteProjectRecord.fromMap).toList(growable: false),
    );
  }
}

class BulkCheckAssetInput {
  const BulkCheckAssetInput({
    required this.deviceAssetId,
    required this.sha256,
  });

  final String deviceAssetId;
  final String sha256;

  Map<String, Object?> toMap() {
    return {'deviceAssetId': deviceAssetId, 'sha256': sha256};
  }
}

class BulkCheckAssetsResponse {
  const BulkCheckAssetsResponse({
    required this.projectId,
    required this.results,
    required this.duplicateCount,
    required this.missingCount,
  });

  final String projectId;
  final List<BulkCheckResult> results;
  final int duplicateCount;
  final int missingCount;

  factory BulkCheckAssetsResponse.fromMap(Map<String, dynamic> map) {
    final rawResults = _asList(map['results']);
    return BulkCheckAssetsResponse(
      projectId: _asString(map['projectId'], fallback: ''),
      results: _asMapList(
        rawResults,
      ).map(BulkCheckResult.fromMap).toList(growable: false),
      duplicateCount: _asInt(map['duplicateCount']),
      missingCount: _asInt(map['missingCount']),
    );
  }
}

class BulkCheckResult {
  const BulkCheckResult({
    required this.deviceAssetId,
    required this.sha256,
    required this.status,
    required this.assetId,
  });

  final String deviceAssetId;
  final String sha256;
  final String status;
  final String? assetId;

  bool get isDuplicate => status == 'duplicate';
  bool get isMissing => status == 'missing';

  factory BulkCheckResult.fromMap(Map<String, dynamic> map) {
    return BulkCheckResult(
      deviceAssetId: _asString(map['deviceAssetId']),
      sha256: _asString(map['sha256']),
      status: _asString(map['status']),
      assetId: _asNullableString(map['assetId']),
    );
  }
}

class PrepareAssetUploadRequest {
  const PrepareAssetUploadRequest({
    required this.projectId,
    required this.sha256,
    required this.mediaType,
    required this.bytes,
    this.filename,
    this.mimeType,
    this.deviceAssetId,
    this.takenAt,
    this.uploadSessionId,
  });

  final String projectId;
  final String sha256;
  final String mediaType;
  final int bytes;
  final String? filename;
  final String? mimeType;
  final String? deviceAssetId;
  final DateTime? takenAt;
  final String? uploadSessionId;

  Map<String, Object?> toMap() {
    return {
      'projectId': projectId,
      'sha256': sha256,
      'mediaType': mediaType,
      'bytes': bytes,
      if (filename != null && filename!.isNotEmpty) 'filename': filename,
      if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
      if (deviceAssetId != null && deviceAssetId!.isNotEmpty)
        'deviceAssetId': deviceAssetId,
      if (takenAt != null) 'takenAt': takenAt!.toIso8601String(),
      if (uploadSessionId != null && uploadSessionId!.isNotEmpty)
        'uploadSessionId': uploadSessionId,
    };
  }
}

class PrepareAssetUploadResponse {
  const PrepareAssetUploadResponse({
    required this.status,
    this.assetId,
    this.provider,
    this.uploadSessionId,
    this.remotePath,
    this.remoteFileId,
    this.instruction,
  });

  final String status;
  final String? assetId;
  final CloudProviderType? provider;
  final String? uploadSessionId;
  final String? remotePath;
  final String? remoteFileId;
  final DirectUploadInstruction? instruction;

  bool get isDuplicate => status == 'duplicate';
  bool get isUploadRequired => status == 'upload_required';

  factory PrepareAssetUploadResponse.fromMap(Map<String, dynamic> map) {
    final providerValue = _asNullableString(
      map['provider'] ?? map['providerType'],
    );

    final rawInstruction = map['upload'];
    final instruction = rawInstruction is Map
        ? DirectUploadInstruction.fromMap(_toStringKeyedMap(rawInstruction))
        : null;

    return PrepareAssetUploadResponse(
      status: _asString(map['status']),
      assetId: _asNullableString(map['assetId']),
      provider: providerValue == null
          ? null
          : CloudProviderTypeX.fromKey(providerValue),
      uploadSessionId: _asNullableString(map['uploadSessionId']),
      remotePath: _asNullableString(
        map['remotePath'] ?? map['path'] ?? map['providerPath'],
      ),
      remoteFileId: _asNullableString(
        map['remoteFileId'] ?? map['providerFileId'] ?? map['fileId'],
      ),
      instruction: instruction,
    );
  }
}

class DirectUploadInstruction {
  const DirectUploadInstruction({
    required this.strategy,
    required this.url,
    required this.method,
    required this.headers,
    required this.fields,
    required this.fileFieldName,
    this.chunkSizeBytes,
    this.completionUrl,
    this.completionMethod,
    this.completionHeaders,
    this.completionBody,
  });

  final String strategy;
  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, String> fields;
  final String fileFieldName;
  final int? chunkSizeBytes;
  final String? completionUrl;
  final String? completionMethod;
  final Map<String, String>? completionHeaders;
  final Map<String, Object?>? completionBody;

  factory DirectUploadInstruction.fromMap(Map<String, dynamic> map) {
    return DirectUploadInstruction(
      strategy: _asString(map['strategy']),
      url: _asString(map['url']),
      method: _asString(map['method'], fallback: 'PUT'),
      headers: _asStringMap(map['headers']),
      fields: _asStringMap(map['fields']),
      fileFieldName: _asString(map['fileFieldName'], fallback: 'file'),
      chunkSizeBytes: _asNullableInt(map['chunkSizeBytes'] ?? map['chunkSize']),
      completionUrl: _asNullableString(map['completionUrl']),
      completionMethod: _asNullableString(map['completionMethod']),
      completionHeaders: _asNullableStringMap(map['completionHeaders']),
      completionBody: _asNullableObjectMap(map['completionBody']),
    );
  }
}

class UploadInstructionResult {
  const UploadInstructionResult({this.remoteFileId, this.rawResponse});

  final String? remoteFileId;
  final Map<String, dynamic>? rawResponse;
}

class CommitAssetRequest {
  const CommitAssetRequest({
    required this.projectId,
    required this.sha256,
    required this.mediaType,
    required this.bytes,
    required this.remotePath,
    this.filename,
    this.mimeType,
    this.durationMs,
    this.takenAt,
    this.deviceAssetId,
    this.uploadSessionId,
    this.provider,
    this.remoteFileId,
    this.expectedRevision,
  });

  final String projectId;
  final String sha256;
  final String mediaType;
  final int bytes;
  final String remotePath;
  final String? filename;
  final String? mimeType;
  final int? durationMs;
  final DateTime? takenAt;
  final String? deviceAssetId;
  final String? uploadSessionId;
  final CloudProviderType? provider;
  final String? remoteFileId;
  final int? expectedRevision;

  Map<String, Object?> toMap() {
    return {
      'projectId': projectId,
      'sha256': sha256,
      'mediaType': mediaType,
      'bytes': bytes,
      'remotePath': remotePath,
      if (filename != null && filename!.isNotEmpty) 'filename': filename,
      if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
      if (durationMs != null) 'durationMs': durationMs,
      if (takenAt != null) 'takenAt': takenAt!.toIso8601String(),
      if (deviceAssetId != null && deviceAssetId!.isNotEmpty)
        'deviceAssetId': deviceAssetId,
      if (uploadSessionId != null && uploadSessionId!.isNotEmpty)
        'uploadSessionId': uploadSessionId,
      if (provider != null) 'provider': provider!.key,
      if (remoteFileId != null && remoteFileId!.isNotEmpty)
        'remoteFileId': remoteFileId,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
    };
  }
}

class CommitAssetResponse {
  const CommitAssetResponse({
    required this.assetId,
    required this.duplicate,
    required this.committed,
    required this.idempotentReplay,
    required this.provider,
    required this.remoteFileId,
    required this.remotePath,
    required this.rawAsset,
    required this.revision,
  });

  final String? assetId;
  final bool duplicate;
  final bool committed;
  final bool idempotentReplay;
  final CloudProviderType? provider;
  final String? remoteFileId;
  final String? remotePath;
  final Map<String, dynamic>? rawAsset;
  final int? revision;

  factory CommitAssetResponse.fromMap(Map<String, dynamic> map) {
    final rawAsset = map['asset'] is Map<String, dynamic>
        ? map['asset'] as Map<String, dynamic>
        : map['asset'] is Map
        ? _toStringKeyedMap(map['asset'] as Map)
        : null;
    final assetIdFromAsset = rawAsset == null
        ? null
        : _asNullableString(rawAsset['id']);
    final providerValue = _asNullableString(
      map['provider'] ?? rawAsset?['provider'] ?? rawAsset?['providerType'],
    );

    return CommitAssetResponse(
      assetId: _asNullableString(map['assetId']) ?? assetIdFromAsset,
      duplicate: _asBool(map['duplicate']),
      committed: _asBool(map['committed']),
      idempotentReplay: _asBool(map['idempotentReplay']),
      provider: providerValue == null
          ? null
          : CloudProviderTypeX.fromKey(providerValue),
      remoteFileId: _asNullableString(
        map['remoteFileId'] ??
            rawAsset?['remoteFileId'] ??
            rawAsset?['providerFileId'] ??
            rawAsset?['fileId'],
      ),
      remotePath: _asNullableString(
        map['remotePath'] ??
            rawAsset?['remotePath'] ??
            rawAsset?['providerPath'] ??
            rawAsset?['path'],
      ),
      rawAsset: rawAsset,
      revision:
          _asNullableInt(map['revision']) ??
          _asNullableInt(rawAsset?['revision']),
    );
  }
}

class MoveAssetResponse {
  const MoveAssetResponse({
    required this.assetId,
    required this.projectId,
    required this.provider,
    required this.remoteFileId,
    required this.remotePath,
    required this.revision,
  });

  final String assetId;
  final String projectId;
  final CloudProviderType? provider;
  final String? remoteFileId;
  final String? remotePath;
  final int? revision;

  factory MoveAssetResponse.fromMap(Map<String, dynamic> map) {
    final providerValue = _asNullableString(
      map['provider'] ?? map['providerType'],
    );
    return MoveAssetResponse(
      assetId: _asString(map['assetId'] ?? map['id']),
      projectId: _asString(map['projectId']),
      provider: providerValue == null
          ? null
          : CloudProviderTypeX.fromKey(providerValue),
      remoteFileId: _asNullableString(
        map['remoteFileId'] ?? map['providerFileId'] ?? map['fileId'],
      ),
      remotePath: _asNullableString(
        map['remotePath'] ?? map['providerPath'] ?? map['path'],
      ),
      revision: _asNullableInt(map['revision']),
    );
  }
}

class ListAssetsRequest {
  const ListAssetsRequest({
    this.cursor,
    this.limit,
    this.projectId,
    this.includeDeleted,
  });

  final String? cursor;
  final int? limit;
  final String? projectId;
  final bool? includeDeleted;

  Map<String, String> toQuery() {
    return {
      if (cursor != null && cursor!.isNotEmpty) 'cursor': cursor!,
      if (limit != null) 'limit': '$limit',
      if (projectId != null && projectId!.isNotEmpty) 'projectId': projectId!,
      if (includeDeleted != null) 'includeDeleted': '$includeDeleted',
    };
  }
}

class ListAssetsResponse {
  const ListAssetsResponse({required this.assets, required this.nextCursor});

  final List<BackendAssetRecord> assets;
  final String? nextCursor;

  factory ListAssetsResponse.fromMap(Map<String, dynamic> map) {
    final rawAssets = _asList(map['assets'] ?? map['items'] ?? map['data']);
    return ListAssetsResponse(
      assets: _asMapList(
        rawAssets,
      ).map(BackendAssetRecord.fromMap).toList(growable: false),
      nextCursor:
          _asNullableString(map['nextCursor']) ??
          _asNullableString(map['cursor']),
    );
  }
}

class BackendAssetRecord {
  const BackendAssetRecord({
    required this.assetId,
    required this.sha256,
    this.projectId,
    this.mediaType,
    this.filename,
    this.mimeType,
    this.bytes,
    this.durationMs,
    this.takenAt,
    this.createdAt,
    this.provider,
    this.remoteFileId,
    this.remotePath,
    this.storageState,
    this.revision,
    this.deleted = false,
    this.softDeletedAt,
    this.hardDeleteDueAt,
    this.purgeRequestedAt,
  });

  final String assetId;
  final String sha256;
  final String? projectId;
  final String? mediaType;
  final String? filename;
  final String? mimeType;
  final int? bytes;
  final int? durationMs;
  final DateTime? takenAt;
  final DateTime? createdAt;
  final CloudProviderType? provider;
  final String? remoteFileId;
  final String? remotePath;
  final String? storageState;
  final int? revision;
  final bool deleted;
  final DateTime? softDeletedAt;
  final DateTime? hardDeleteDueAt;
  final DateTime? purgeRequestedAt;

  factory BackendAssetRecord.fromMap(Map<String, dynamic> map) {
    final id = _asNullableString(map['id']) ?? _asString(map['assetId']);
    final sha = _asNullableString(map['sha256']) ?? _asString(map['hash']);
    final providerValue = _asNullableString(
      map['provider'] ?? map['providerType'],
    );

    return BackendAssetRecord(
      assetId: id,
      sha256: sha,
      projectId:
          _asNullableString(map['projectId']) ??
          _asNullableString(map['project_id']),
      mediaType:
          _asNullableString(map['mediaType']) ??
          _asNullableString(map['media_type']),
      filename: _asNullableString(map['filename']),
      mimeType:
          _asNullableString(map['mimeType']) ??
          _asNullableString(map['mime_type']),
      bytes: _asNullableInt(map['bytes']),
      durationMs:
          _asNullableInt(map['durationMs']) ??
          _asNullableInt(map['duration_ms']),
      takenAt:
          _asNullableDateTime(map['takenAt']) ??
          _asNullableDateTime(map['taken_at']),
      createdAt:
          _asNullableDateTime(map['createdAt']) ??
          _asNullableDateTime(map['created_at']),
      provider: providerValue == null
          ? null
          : CloudProviderTypeX.fromKey(providerValue),
      remoteFileId: _asNullableString(
        map['remoteFileId'] ?? map['providerFileId'] ?? map['fileId'],
      ),
      remotePath: _asNullableString(
        map['remotePath'] ?? map['providerPath'] ?? map['path'],
      ),
      storageState:
          _asNullableString(map['storageState']) ??
          _asNullableString(map['storage_state']),
      revision:
          _asNullableInt(map['revision']) ?? _asNullableInt(map['remote_rev']),
      deleted:
          _asBool(map['deleted']) ||
          _asNullableString(map['status']) == 'deleted',
      softDeletedAt:
          _asNullableDateTime(map['softDeletedAt']) ??
          _asNullableDateTime(map['soft_deleted_at']),
      hardDeleteDueAt:
          _asNullableDateTime(map['hardDeleteDueAt']) ??
          _asNullableDateTime(map['hard_delete_due_at']),
      purgeRequestedAt:
          _asNullableDateTime(map['purgeRequestedAt']) ??
          _asNullableDateTime(map['purge_requested_at']),
    );
  }
}

class SignedMediaUrlResponse {
  const SignedMediaUrlResponse({required this.url, required this.ttlSec});

  final String url;
  final int ttlSec;

  factory SignedMediaUrlResponse.fromMap(Map<String, dynamic> map) {
    return SignedMediaUrlResponse(
      url: _asNullableString(map['url']) ?? _asString(map['signedUrl']),
      ttlSec:
          _asNullableInt(map['ttlSec']) ??
          _asNullableInt(map['expiresInSec']) ??
          300,
    );
  }
}

List<dynamic> _asList(Object? value) {
  if (value is List<dynamic>) {
    return value;
  }
  if (value is List) {
    return value.cast<dynamic>();
  }
  return const [];
}

List<Map<String, dynamic>> _asMapList(List<dynamic> items) {
  return items.whereType<Map>().map(_toStringKeyedMap).toList(growable: false);
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return _toStringKeyedMap(value);
  }
  return const <String, dynamic>{};
}

Map<String, dynamic> _toStringKeyedMap(Map<dynamic, dynamic> item) {
  return item.map((key, value) => MapEntry('$key', value));
}

Map<String, Object?>? _asNullableObjectMap(Object? value) {
  if (value is Map) {
    return value.map((key, data) => MapEntry('$key', data));
  }
  return null;
}

Map<String, String> _asStringMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return value.map((key, data) => MapEntry('$key', '$data'));
}

Map<String, String>? _asNullableStringMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.map((key, data) => MapEntry('$key', '$data'));
}

String _asString(Object? value, {String? fallback}) {
  final stringValue = _asNullableString(value);
  if (stringValue != null && stringValue.isNotEmpty) {
    return stringValue;
  }
  if (fallback != null) {
    return fallback;
  }
  throw FormatException('Expected non-empty string value, got: $value');
}

String? _asNullableString(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  return value.toString();
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

int? _asNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

bool _asBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    return value.toLowerCase() == 'true' || value == '1';
  }
  return false;
}

DateTime? _asNullableDateTime(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
