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

  test(
    'migrates projects table to add notes and start_date columns with default values',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('joblens_db_test_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final legacy = await openDatabase(
        dbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            cover_asset_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            sync_folder_map TEXT NOT NULL DEFAULT '{}'
          )
        ''');
          await db.execute('''
          CREATE TABLE photo_assets (
            id TEXT PRIMARY KEY,
            local_path TEXT NOT NULL,
            thumb_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            imported_at TEXT NOT NULL,
            project_id INTEGER NOT NULL,
            hash TEXT NOT NULL,
            status TEXT NOT NULL,
            source_type TEXT NOT NULL,
            FOREIGN KEY(project_id) REFERENCES projects(id)
          )
        ''');
        },
      );

      await legacy.insert('projects', {
        'name': 'Inbox',
        'cover_asset_id': null,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_folder_map': '{}',
      });
      await legacy.close();

      final upgraded = await AppDatabase.open(databasePath: dbPath);
      await upgraded.close();

      final db = await openDatabase(dbPath);
      final columns = await db.rawQuery('PRAGMA table_info(projects)');
      final names = columns.map((row) => row['name']).toList();
      expect(names, contains('notes'));
      expect(names, contains('start_date'));

      final rows = await db.query(
        'projects',
        columns: ['notes', 'start_date'],
        limit: 1,
      );
      expect(rows, isNotEmpty);
      expect(rows.first['notes'], '');
      expect(rows.first['start_date'], isNull);
      await db.close();
    },
  );
}
