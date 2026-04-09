import 'dart:convert';

enum SyncEntityType { project, asset }

class EntitySyncRecord {
  const EntitySyncRecord({
    required this.entityType,
    required this.entityId,
    required this.nextAttemptAt,
    required this.attempts,
    required this.leasedUntil,
    required this.lastError,
    required this.dirtyFields,
    required this.baseRemoteRev,
    required this.localSeq,
    required this.createdAt,
    required this.updatedAt,
  });

  final SyncEntityType entityType;
  final String entityId;
  final DateTime? nextAttemptAt;
  final int attempts;
  final DateTime? leasedUntil;
  final String? lastError;
  final List<String> dirtyFields;
  final int? baseRemoteRev;
  final int localSeq;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isLeased => leasedUntil != null && leasedUntil!.isAfter(DateTime.now());
  bool get hasError => lastError != null && lastError!.trim().isNotEmpty;

  Map<String, Object?> toMap() {
    return {
      'entity_type': entityType.name,
      'entity_id': entityId,
      'next_attempt_at': nextAttemptAt?.toIso8601String(),
      'attempts': attempts,
      'leased_until': leasedUntil?.toIso8601String(),
      'last_error': lastError,
      'dirty_fields': jsonEncode(dirtyFields),
      'base_remote_rev': baseRemoteRev,
      'local_seq': localSeq,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory EntitySyncRecord.fromMap(Map<String, Object?> map) {
    return EntitySyncRecord(
      entityType: SyncEntityType.values.byName(map['entity_type']! as String),
      entityId: map['entity_id']! as String,
      nextAttemptAt: (map['next_attempt_at'] as String?) == null
          ? null
          : DateTime.parse(map['next_attempt_at']! as String),
      attempts: map['attempts']! as int,
      leasedUntil: (map['leased_until'] as String?) == null
          ? null
          : DateTime.parse(map['leased_until']! as String),
      lastError: map['last_error'] as String?,
      dirtyFields: ((jsonDecode((map['dirty_fields'] as String?) ?? '[]')
              as List<dynamic>))
          .map((item) => item.toString())
          .toList(growable: false),
      baseRemoteRev: map['base_remote_rev'] as int?,
      localSeq: (map['local_seq'] as int?) ?? 0,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }
}
