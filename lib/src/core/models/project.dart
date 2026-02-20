import 'dart:convert';

class Project {
  const Project({
    required this.id,
    required this.name,
    required this.coverAssetId,
    required this.createdAt,
    required this.updatedAt,
    required this.syncFolderMap,
  });

  final int id;
  final String name;
  final String? coverAssetId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, String> syncFolderMap;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'cover_asset_id': coverAssetId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'sync_folder_map': jsonEncode(syncFolderMap),
    };
  }

  factory Project.fromMap(Map<String, Object?> map) {
    final rawMap = map['sync_folder_map'] as String? ?? '{}';
    final decoded = jsonDecode(rawMap) as Map<String, dynamic>;
    return Project(
      id: map['id']! as int,
      name: map['name']! as String,
      coverAssetId: map['cover_asset_id'] as String?,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
      syncFolderMap: decoded.map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );
  }
}
