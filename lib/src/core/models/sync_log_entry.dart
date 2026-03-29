enum SyncLogLevel { info, error }

class SyncLogEntry {
  const SyncLogEntry({
    required this.id,
    required this.level,
    required this.event,
    required this.message,
    required this.createdAt,
    this.assetId,
    this.projectId,
  });

  final int id;
  final SyncLogLevel level;
  final String event;
  final String message;
  final DateTime createdAt;
  final String? assetId;
  final int? projectId;

  bool get isError => level == SyncLogLevel.error;

  factory SyncLogEntry.fromMap(Map<String, Object?> map) {
    return SyncLogEntry(
      id: map['id']! as int,
      level: SyncLogLevel.values.byName(map['level']! as String),
      event: map['event']! as String,
      message: map['message']! as String,
      createdAt: DateTime.parse(map['created_at']! as String),
      assetId: map['asset_id'] as String?,
      projectId: map['project_id'] as int?,
    );
  }
}
