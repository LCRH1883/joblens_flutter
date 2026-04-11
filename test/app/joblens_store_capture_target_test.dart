import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/capture_target_preference.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'capture target preference resolves inbox, legacy last used, and fixed project',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_capture_target_test_',
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
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.createProject('Alpha');
      await store.createProject('Bravo');

      expect(store.resolveCaptureTarget().projectName, 'Inbox');

      final alpha = store.projects.firstWhere(
        (project) => project.name == 'Alpha',
      );
      await database.setCaptureTargetMode(CaptureTargetMode.lastUsed);
      await database.setCaptureLastUsedProjectId(alpha.id);
      await store.refresh();
      expect(store.resolveCaptureTarget().projectName, 'Alpha');

      final bravo = store.projects.firstWhere(
        (project) => project.name == 'Bravo',
      );
      await database.setCaptureTargetMode(CaptureTargetMode.fixedProject);
      await database.setCaptureFixedProjectId(bravo.id);
      await store.refresh();
      expect(store.resolveCaptureTarget().projectName, 'Bravo');

      await database.setCaptureTargetMode(CaptureTargetMode.lastUsed);
      await database.setCaptureLastUsedProjectId(999999);
      await store.refresh();
      expect(store.resolveCaptureTarget().projectName, 'Inbox');
    },
  );
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}
