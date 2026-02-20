import 'package:intl/intl.dart';

enum AssetSourceType { captured, imported }

enum AssetStatus { active, deleted }

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

  String get dayLabel => DateFormat('EEE, MMM d, y').format(createdAt);

  PhotoAsset copyWith({
    int? projectId,
    AssetStatus? status,
    String? thumbPath,
  }) {
    return PhotoAsset(
      id: id,
      localPath: localPath,
      thumbPath: thumbPath ?? this.thumbPath,
      createdAt: createdAt,
      importedAt: importedAt,
      projectId: projectId ?? this.projectId,
      hash: hash,
      status: status ?? this.status,
      sourceType: sourceType,
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
    );
  }
}
