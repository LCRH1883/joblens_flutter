import 'package:intl/intl.dart';

enum AssetSourceType { captured, imported }

enum AssetStatus { active, deleted }

class AssetCloudState {
  static const localAndCloud = 'local_and_cloud';
  static const cloudOnly = 'cloud_only';
  static const deleted = 'deleted';
}

class PhotoAsset {
  const PhotoAsset({
    required this.id,
    required this.localPath,
    required this.thumbPath,
    required this.createdAt,
    required this.importedAt,
    required this.projectId,
    required this.hash,
    required this.status,
    required this.sourceType,
    required this.cloudState,
    this.remoteAssetId,
    this.remoteProvider,
    this.remoteFileId,
    this.uploadSessionId,
    this.uploadPath,
    this.lastSyncErrorCode,
  });

  final String id;
  final String localPath;
  final String thumbPath;
  final DateTime createdAt;
  final DateTime importedAt;
  final int projectId;
  final String hash;
  final AssetStatus status;
  final AssetSourceType sourceType;
  final String cloudState;
  final String? remoteAssetId;
  final String? remoteProvider;
  final String? remoteFileId;
  final String? uploadSessionId;
  final String? uploadPath;
  final String? lastSyncErrorCode;

  String get dayLabel => DateFormat('EEE, MMM d, y').format(createdAt);

  PhotoAsset copyWith({
    String? localPath,
    int? projectId,
    AssetStatus? status,
    String? thumbPath,
    String? cloudState,
    String? remoteAssetId,
    String? remoteProvider,
    String? remoteFileId,
    String? uploadSessionId,
    String? uploadPath,
    String? lastSyncErrorCode,
  }) {
    return PhotoAsset(
      id: id,
      localPath: localPath ?? this.localPath,
      thumbPath: thumbPath ?? this.thumbPath,
      createdAt: createdAt,
      importedAt: importedAt,
      projectId: projectId ?? this.projectId,
      hash: hash,
      status: status ?? this.status,
      sourceType: sourceType,
      cloudState: cloudState ?? this.cloudState,
      remoteAssetId: remoteAssetId ?? this.remoteAssetId,
      remoteProvider: remoteProvider ?? this.remoteProvider,
      remoteFileId: remoteFileId ?? this.remoteFileId,
      uploadSessionId: uploadSessionId ?? this.uploadSessionId,
      uploadPath: uploadPath ?? this.uploadPath,
      lastSyncErrorCode: lastSyncErrorCode ?? this.lastSyncErrorCode,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'local_path': localPath,
      'thumb_path': thumbPath,
      'created_at': createdAt.toIso8601String(),
      'imported_at': importedAt.toIso8601String(),
      'project_id': projectId,
      'hash': hash,
      'status': status.name,
      'source_type': sourceType.name,
      'remote_asset_id': remoteAssetId,
      'remote_provider': remoteProvider,
      'remote_file_id': remoteFileId,
      'upload_session_id': uploadSessionId,
      'upload_path': uploadPath,
      'cloud_state': cloudState,
      'last_sync_error_code': lastSyncErrorCode,
    };
  }

  factory PhotoAsset.fromMap(Map<String, Object?> map) {
    return PhotoAsset(
      id: map['id']! as String,
      localPath: map['local_path']! as String,
      thumbPath: map['thumb_path']! as String,
      createdAt: DateTime.parse(map['created_at']! as String),
      importedAt: DateTime.parse(map['imported_at']! as String),
      projectId: map['project_id']! as int,
      hash: map['hash']! as String,
      status: AssetStatus.values.byName(map['status']! as String),
      sourceType: AssetSourceType.values.byName(map['source_type']! as String),
      cloudState:
          (map['cloud_state'] as String?) ?? AssetCloudState.localAndCloud,
      remoteAssetId: map['remote_asset_id'] as String?,
      remoteProvider: map['remote_provider'] as String?,
      remoteFileId: map['remote_file_id'] as String?,
      uploadSessionId: map['upload_session_id'] as String?,
      uploadPath: map['upload_path'] as String?,
      lastSyncErrorCode: map['last_sync_error_code'] as String?,
    );
  }
}
