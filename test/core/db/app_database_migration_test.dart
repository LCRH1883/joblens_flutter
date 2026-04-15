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

  test(
    'migrates project name uniqueness so deleted projects do not block recreation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_db_project_name_migration_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final legacy = await openDatabase(
        dbPath,
        version: 15,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            notes TEXT NOT NULL DEFAULT '',
            start_date TEXT,
            remote_project_id TEXT,
            cover_asset_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            sync_folder_map TEXT NOT NULL DEFAULT '{}',
            deleted_at TEXT,
            remote_rev INTEGER,
            local_seq INTEGER NOT NULL DEFAULT 0,
            dirty_fields TEXT NOT NULL DEFAULT '[]'
          )
        ''');
          await db.execute('''
          CREATE TABLE entity_sync (
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            next_attempt_at TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            leased_until TEXT,
            last_error TEXT,
            dirty_fields TEXT NOT NULL DEFAULT '[]',
            base_remote_rev INTEGER,
            local_seq INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (entity_type, entity_id)
          )
        ''');
        },
      );

      final now = DateTime.now().toIso8601String();
      await legacy.insert('projects', {
        'name': 'Test',
        'notes': '',
        'start_date': null,
        'remote_project_id': null,
        'cover_asset_id': null,
        'created_at': now,
        'updated_at': now,
        'sync_folder_map': '{}',
        'deleted_at': now,
        'remote_rev': null,
        'local_seq': 0,
        'dirty_fields': '["deleted_at"]',
      });
      await legacy.close();

      final upgraded = await AppDatabase.open(databasePath: dbPath);
      final recreatedId = await upgraded.createProject('Test');
      final recreated = await upgraded.getProjectById(recreatedId);
      final allProjects = await upgraded.getProjects(includeDeleted: true);
      await upgraded.close();

      expect(recreated, isNotNull);
      expect(recreated?.deletedAt, isNull);
      expect(
        allProjects.where((project) => project.name == 'Test'),
        hasLength(2),
      );

      final db = await openDatabase(dbPath);
      final schema = await db.query(
        'sqlite_master',
        columns: ['sql'],
        where: 'type = ? AND name = ?',
        whereArgs: ['table', 'projects'],
        limit: 1,
      );
      expect(schema, isNotEmpty);
      expect(
        (schema.first['sql'] as String?) ?? '',
        isNot(contains('name TEXT NOT NULL UNIQUE')),
      );

      final indexes = await db.rawQuery('PRAGMA index_list(projects)');
      final indexNames = indexes
          .map((row) => row['name'])
          .toList(growable: false);
      expect(indexNames, contains('idx_projects_active_name_unique'));
      await db.close();
    },
  );
}
