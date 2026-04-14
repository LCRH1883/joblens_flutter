import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/db/app_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('migrates schema from v14 to add camera session metrics table', () async {
    final tempDir = await Directory.systemTemp.createTemp('joblens_camera_metrics_migration_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final legacy = await openDatabase(
      dbPath,
      version: 14,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE sync_log_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, event TEXT NOT NULL, message TEXT NOT NULL, asset_id TEXT, project_id INTEGER, created_at TEXT NOT NULL)');
      },
    );
    await legacy.close();

    final upgraded = await AppDatabase.open(databasePath: dbPath);
    await upgraded.close();

    final db = await openDatabase(dbPath);
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='camera_session_metrics'",
    );
    expect(rows, isNotEmpty);

    final columns = await db.rawQuery('PRAGMA table_info(camera_session_metrics)');
    final names = columns.map((row) => row['name']).toList(growable: false);
    expect(names, contains('session_id'));
    expect(names, contains('open_to_preview_ready_ms'));
    expect(names, contains('last_capture_local_save_ms'));
    expect(names, contains('last_lens_switch_ms'));
    expect(names, contains('last_target_picker_open_ms'));
    expect(names, contains('capture_attempt_count'));
    expect(names, contains('abandoned'));
    await db.close();
  });
}
