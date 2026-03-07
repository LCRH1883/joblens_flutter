import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/models/project.dart';

void main() {
  test('Project.toMap/fromMap round-trips notes', () {
    final original = Project(
      id: 7,
      name: 'Library A',
      notes: 'First line\nSecond line',
      remoteProjectId: 'remote-project-1',
      coverAssetId: 'asset-1',
      createdAt: DateTime.parse('2026-01-02T03:04:05.000'),
      updatedAt: DateTime.parse('2026-01-03T03:04:05.000'),
      syncFolderMap: const {'gdrive': 'folder-123'},
    );

    final map = original.toMap();
    final parsed = Project.fromMap(map);

    expect(parsed.id, original.id);
    expect(parsed.name, original.name);
    expect(parsed.notes, original.notes);
    expect(parsed.remoteProjectId, original.remoteProjectId);
    expect(parsed.coverAssetId, original.coverAssetId);
    expect(parsed.createdAt, original.createdAt);
    expect(parsed.updatedAt, original.updatedAt);
    expect(parsed.syncFolderMap, original.syncFolderMap);
  });
}
