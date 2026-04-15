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

  test(
    'projects stay sorted with Inbox first and sort mode persists',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_sort_test_',
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
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.createProject('Zulu', startDate: DateTime(2026, 2, 1));
      await store.createProject('Alpha', startDate: DateTime(2026, 3, 1));
      await store.createProject('Bravo', startDate: DateTime(2026, 1, 1));

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
    },
  );

  test(
    'creating a project with an existing name reuses the local project',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_project_duplicate_test_',
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
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.createProject('Plumbing');
      await store.createProject('Plumbing');

      final plumbingProjects = store.projects
          .where((project) => project.name == 'Plumbing')
          .toList(growable: false);
      expect(plumbingProjects, hasLength(1));
      expect(store.lastError, isNull);
    },
  );

  test('creating a project after deleting the same name succeeds', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_project_recreate_test_',
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
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.createProject('Test');
    final originalProject = store.projects.singleWhere(
      (project) => project.name == 'Test',
    );

    await store.deleteProject(originalProject.id);
    await store.createProject('Test');

    final activeProjects = store.projects
        .where((project) => project.name == 'Test')
        .toList(growable: false);
    expect(activeProjects, hasLength(1));
    expect(activeProjects.single.id, isNot(originalProject.id));

    final allProjects = await database.getProjects(includeDeleted: true);
    final matchingProjects = allProjects
        .where((project) => project.name == 'Test')
        .toList(growable: false);
    expect(matchingProjects, hasLength(2));
    expect(
      matchingProjects.where((project) => project.deletedAt == null),
      hasLength(1),
    );
    expect(
      matchingProjects.where((project) => project.deletedAt != null),
      hasLength(1),
    );
    expect(store.lastError, isNull);
  });
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}
