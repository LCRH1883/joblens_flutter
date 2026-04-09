import 'backend_api_payloads.dart';

class BackendSyncEvent {
  const BackendSyncEvent({
    required this.id,
    required this.projectId,
    required this.eventType,
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.createdAt,
  });

  final int id;
  final String? projectId;
  final String eventType;
  final String entityType;
  final String entityId;
  final Map<String, Object?> payload;
  final DateTime? createdAt;

  factory BackendSyncEvent.fromMap(Map<String, dynamic> map) {
    return BackendSyncEvent(
      id: (map['id'] as num).toInt(),
      projectId: map['project_id'] as String? ?? map['projectId'] as String?,
      eventType: (map['event_type'] ?? map['eventType']) as String,
      entityType: (map['entity_type'] ?? map['entityType']) as String,
      entityId: (map['entity_id'] ?? map['entityId']) as String,
      payload: toObjectMap(map['payload']),
      createdAt: DateTime.tryParse(
        (map['created_at'] ?? map['createdAt'] ?? '').toString(),
      ),
    );
  }
}

class SyncEventsResponse {
  const SyncEventsResponse({
    required this.events,
    required this.nextAfter,
    required this.hasMore,
  });

  final List<BackendSyncEvent> events;
  final int nextAfter;
  final bool hasMore;

  factory SyncEventsResponse.fromMap(Map<String, dynamic> map) {
    final raw = map['events'] as List<dynamic>? ?? const [];
    return SyncEventsResponse(
      events: raw
          .whereType<Map>()
          .map((item) => BackendSyncEvent.fromMap(
                item.map((key, value) => MapEntry('$key', value)),
              ))
          .toList(growable: false),
      nextAfter: (map['nextAfter'] as num?)?.toInt() ?? 0,
      hasMore: map['hasMore'] == true,
    );
  }
}
