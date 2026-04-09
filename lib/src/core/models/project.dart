import 'dart:convert';

enum ProjectSortMode {
  name('name'),
  startDate('start_date');

  const ProjectSortMode(this.storageValue);

  final String storageValue;

  static ProjectSortMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) {
        return mode;
      }
    }
    return ProjectSortMode.name;
  }
}

class Project {
  const Project({
    required this.id,
    required this.name,
    required this.notes,
    required this.startDate,
    required this.remoteProjectId,
    required this.coverAssetId,
    required this.createdAt,
    required this.updatedAt,
    required this.syncFolderMap,
    this.deletedAt,
    this.remoteRev,
    this.localSeq = 0,
    this.dirtyFields = const [],
  });

  final int id;
  final String name;
  final String notes;
  final DateTime? startDate;
  final String? remoteProjectId;
  final String? coverAssetId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, String> syncFolderMap;
  final DateTime? deletedAt;
  final int? remoteRev;
  final int localSeq;
  final List<String> dirtyFields;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'notes': notes,
      'start_date': startDate?.toIso8601String(),
      'remote_project_id': remoteProjectId,
      'cover_asset_id': coverAssetId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'sync_folder_map': jsonEncode(syncFolderMap),
      'deleted_at': deletedAt?.toIso8601String(),
      'remote_rev': remoteRev,
      'local_seq': localSeq,
      'dirty_fields': jsonEncode(dirtyFields),
    };
  }

  factory Project.fromMap(Map<String, Object?> map) {
    final rawMap = map['sync_folder_map'] as String? ?? '{}';
    final decoded = jsonDecode(rawMap) as Map<String, dynamic>;
    return Project(
      id: map['id']! as int,
      name: map['name']! as String,
      notes: (map['notes'] as String?) ?? '',
      startDate: (map['start_date'] as String?) == null
          ? null
          : DateTime.parse(map['start_date']! as String),
      remoteProjectId: map['remote_project_id'] as String?,
      coverAssetId: map['cover_asset_id'] as String?,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
      syncFolderMap: decoded.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      deletedAt: (map['deleted_at'] as String?) == null
          ? null
          : DateTime.parse(map['deleted_at']! as String),
      remoteRev: map['remote_rev'] as int?,
      localSeq: (map['local_seq'] as int?) ?? 0,
      dirtyFields: ((jsonDecode((map['dirty_fields'] as String?) ?? '[]')
              as List<dynamic>))
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}
