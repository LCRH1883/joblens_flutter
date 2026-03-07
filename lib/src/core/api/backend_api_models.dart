import '../models/cloud_provider.dart';

class ProviderConnectionSummary {
  const ProviderConnectionSummary({
    required this.provider,
    required this.status,
    this.connectedAt,
    this.lastError,
  });

  final CloudProviderType provider;
  final String status;
  final DateTime? connectedAt;
  final String? lastError;

  bool get isConnected => status == 'connected';
  bool get isExpired => status == 'expired';

  factory ProviderConnectionSummary.fromMap(Map<String, dynamic> map) {
    return ProviderConnectionSummary(
      provider: CloudProviderTypeX.fromKey(
        _asString(map['provider'] ?? map['providerType']),
      ),
      status: _asString(map['status'], fallback: 'disconnected'),
      connectedAt: _asNullableDateTime(
        map['connectedAt'] ?? map['connected_at'],
      ),
      lastError: _asNullableString(map['lastError'] ?? map['last_error']),
    );
  }
}

class ProviderConnectionsResponse {
  const ProviderConnectionsResponse({required this.connections});

  final List<ProviderConnectionSummary> connections;

  factory ProviderConnectionsResponse.fromMap(Map<String, dynamic> map) {
    final raw = _asList(map['connections'] ?? map['providers']);
    return ProviderConnectionsResponse(
      connections: _asMapList(raw)
          .map(ProviderConnectionSummary.fromMap)
          .toList(growable: false),
    );
  }
}

class BeginProviderConnectionResponse {
  const BeginProviderConnectionResponse({
    required this.authorizationUrl,
  });

  final String authorizationUrl;

  factory BeginProviderConnectionResponse.fromMap(Map<String, dynamic> map) {
    return BeginProviderConnectionResponse(
      authorizationUrl: _asString(
        map['authorizationUrl'] ?? map['authUrl'] ?? map['url'],
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
  });

  final int localProjectId;
  final String name;
  final String? remoteProjectId;

  Map<String, Object?> toMap() {
    return {
      'localProjectId': localProjectId,
      'name': name,
      if (remoteProjectId != null && remoteProjectId!.isNotEmpty)
        'projectId': remoteProjectId,
    };
  }
}

class RemoteProjectRecord {
  const RemoteProjectRecord({
    required this.projectId,
    required this.name,
  });

  final String projectId;
  final String name;

  factory RemoteProjectRecord.fromMap(Map<String, dynamic> map) {
    return RemoteProjectRecord(
      projectId: _asString(map['projectId'] ?? map['id']),
      name: _asString(map['name']),
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
    return {
      'deviceAssetId': deviceAssetId,
      'sha256': sha256,
    };
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
      results: _asMapList(rawResults)
          .map(BulkCheckResult.fromMap)
          .toList(growable: false),
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
      chunkSizeBytes: _asNullableInt(
        map['chunkSizeBytes'] ?? map['chunkSize'],
      ),
      completionUrl: _asNullableString(map['completionUrl']),
      completionMethod: _asNullableString(map['completionMethod']),
      completionHeaders: _asNullableStringMap(map['completionHeaders']),
      completionBody: _asNullableObjectMap(map['completionBody']),
    );
  }
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
  });

  final String? assetId;
  final bool duplicate;
  final bool committed;
  final bool idempotentReplay;
  final CloudProviderType? provider;
  final String? remoteFileId;
  final String? remotePath;
  final Map<String, dynamic>? rawAsset;

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
      map['provider'] ??
          rawAsset?['provider'] ??
          rawAsset?['providerType'],
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
  const ListAssetsResponse({
    required this.assets,
    required this.nextCursor,
  });

  final List<BackendAssetRecord> assets;
  final String? nextCursor;

  factory ListAssetsResponse.fromMap(Map<String, dynamic> map) {
    final rawAssets = _asList(map['assets'] ?? map['items'] ?? map['data']);
    return ListAssetsResponse(
      assets: _asMapList(rawAssets)
          .map(BackendAssetRecord.fromMap)
          .toList(growable: false),
      nextCursor:
          _asNullableString(map['nextCursor']) ?? _asNullableString(map['cursor']),
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
    this.deleted = false,
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
  final bool deleted;

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
          _asNullableString(map['projectId']) ?? _asNullableString(map['project_id']),
      mediaType:
          _asNullableString(map['mediaType']) ?? _asNullableString(map['media_type']),
      filename: _asNullableString(map['filename']),
      mimeType:
          _asNullableString(map['mimeType']) ?? _asNullableString(map['mime_type']),
      bytes: _asNullableInt(map['bytes']),
      durationMs:
          _asNullableInt(map['durationMs']) ?? _asNullableInt(map['duration_ms']),
      takenAt:
          _asNullableDateTime(map['takenAt']) ?? _asNullableDateTime(map['taken_at']),
      createdAt: _asNullableDateTime(map['createdAt']) ??
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
      deleted: _asBool(map['deleted']) || _asNullableString(map['status']) == 'deleted',
    );
  }
}

class SignedMediaUrlResponse {
  const SignedMediaUrlResponse({
    required this.url,
    required this.ttlSec,
  });

  final String url;
  final int ttlSec;

  factory SignedMediaUrlResponse.fromMap(Map<String, dynamic> map) {
    return SignedMediaUrlResponse(
      url: _asNullableString(map['url']) ?? _asString(map['signedUrl']),
      ttlSec:
          _asNullableInt(map['ttlSec']) ?? _asNullableInt(map['expiresInSec']) ?? 300,
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
  return items
      .whereType<Map>()
      .map(_toStringKeyedMap)
      .toList(growable: false);
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
