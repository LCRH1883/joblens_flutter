enum BlobUploadState { queued, uploading, failed }

class BlobUploadTask {
  const BlobUploadTask({
    required this.assetId,
    required this.uploadGeneration,
    required this.localUri,
    required this.state,
    required this.bytesSent,
    required this.attempts,
    required this.leasedUntil,
    required this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  final String assetId;
  final int uploadGeneration;
  final String localUri;
  final BlobUploadState state;
  final int bytesSent;
  final int attempts;
  final DateTime? leasedUntil;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toMap() {
    return {
      'asset_id': assetId,
      'upload_generation': uploadGeneration,
      'local_uri': localUri,
      'state': state.name,
      'bytes_sent': bytesSent,
      'attempts': attempts,
      'leased_until': leasedUntil?.toIso8601String(),
      'last_error': lastError,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory BlobUploadTask.fromMap(Map<String, Object?> map) {
    return BlobUploadTask(
      assetId: map['asset_id']! as String,
      uploadGeneration: map['upload_generation']! as int,
      localUri: map['local_uri']! as String,
      state: BlobUploadState.values.byName(map['state']! as String),
      bytesSent: (map['bytes_sent'] as int?) ?? 0,
      attempts: map['attempts']! as int,
      leasedUntil: (map['leased_until'] as String?) == null
          ? null
          : DateTime.parse(map['leased_until']! as String),
      lastError: map['last_error'] as String?,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }
}
