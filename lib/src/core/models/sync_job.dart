import 'cloud_provider.dart';

enum SyncJobState { queued, uploading, done, failed, paused }

class SyncJob {
  const SyncJob({
    required this.id,
    required this.assetId,
    required this.providerType,
    required this.projectId,
    required this.attemptCount,
    required this.state,
    required this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String assetId;
  final CloudProviderType providerType;
  final int projectId;
  final int attemptCount;
  final SyncJobState state;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  SyncJob copyWith({
    int? attemptCount,
    SyncJobState? state,
    String? lastError,
    DateTime? updatedAt,
  }) {
    return SyncJob(
      id: id,
      assetId: assetId,
      providerType: providerType,
      projectId: projectId,
      attemptCount: attemptCount ?? this.attemptCount,
      state: state ?? this.state,
      lastError: lastError,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'asset_id': assetId,
      'provider_type': providerType.key,
      'project_id': projectId,
      'attempt_count': attemptCount,
      'state': state.name,
      'last_error': lastError,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory SyncJob.fromMap(Map<String, Object?> map) {
    return SyncJob(
      id: map['id']! as String,
      assetId: map['asset_id']! as String,
      providerType: CloudProviderTypeX.fromKey(map['provider_type']! as String),
      projectId: map['project_id']! as int,
      attemptCount: map['attempt_count']! as int,
      state: SyncJobState.values.byName(map['state']! as String),
      lastError: map['last_error'] as String?,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }
}
