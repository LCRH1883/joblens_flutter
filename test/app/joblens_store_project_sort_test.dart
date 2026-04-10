import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('projects stay sorted with Inbox first and sort mode persists', () async {
    final tempDir = await Directory.systemTemp.createTemp('joblens_sort_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: _NoopSyncService(database),
    );
    addTearDown(() async {
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.createProject(
      'Zulu',
      startDate: DateTime(2026, 2, 1),
    );
    await store.createProject(
      'Alpha',
      startDate: DateTime(2026, 3, 1),
    );
    await store.createProject(
      'Bravo',
      startDate: DateTime(2026, 1, 1),
    );

    expect(store.projects.map((project) => project.name).toList(), [
      'Inbox',
      'Alpha',
      'Bravo',
      'Zulu',
    ]);

    await store.setProjectSortMode(ProjectSortMode.startDate);
    expect(store.projects.map((project) => project.name).toList(), [
      'Inbox',
      'Bravo',
      'Zulu',
      'Alpha',
    ]);

    await store.setProjectSortMode(ProjectSortMode.name);
    await store.refresh();
    expect(store.projectSortMode, ProjectSortMode.name);
    expect(store.projects.first.name, 'Inbox');
  });
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}
