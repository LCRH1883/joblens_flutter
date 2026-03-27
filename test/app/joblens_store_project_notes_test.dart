import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('updateProjectNotes persists notes and refreshes projects', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_store_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    final mediaStorage = await MediaStorageService.create(
      rootDirectory: tempDir,
    );
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
    );

    await store.initialize();
    await store.createProject('Library Notes');

    final target = store.projects.firstWhere(
      (project) => project.name == 'Library Notes',
    );
    await store.updateProjectNotes(target.id, 'line one   \nline two\t  ');

    final updated = store.projects.firstWhere(
      (project) => project.id == target.id,
    );
    expect(updated.notes, 'line one\nline two');
    expect(store.lastError, isNull);

    await database.close();
  });
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> enqueueAsset(PhotoAsset asset) async {}

  @override
  Future<void> processQueue(List<Project> projects) async {}
}
