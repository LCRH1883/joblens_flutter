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

  test('migrates schema from v5 to v6 with sync log table', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_db_sync_log_migration_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final legacy = await openDatabase(
      dbPath,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            notes TEXT NOT NULL DEFAULT '',
            remote_project_id TEXT,
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
            remote_asset_id TEXT,
            remote_provider TEXT,
            remote_file_id TEXT,
            upload_session_id TEXT,
            upload_path TEXT,
            cloud_state TEXT NOT NULL DEFAULT 'local_and_cloud',
            last_sync_error_code TEXT,
            FOREIGN KEY(project_id) REFERENCES projects(id)
          )
        ''');
        await db.execute('''
          CREATE TABLE provider_accounts (
            id TEXT PRIMARY KEY,
            provider_type TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            token_state TEXT NOT NULL,
            connected_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_jobs (
            id TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL,
            provider_type TEXT NOT NULL,
            project_id INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL,
            state TEXT NOT NULL,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(asset_id) REFERENCES photo_assets(id),
            FOREIGN KEY(project_id) REFERENCES projects(id)
          )
        ''');
        await db.execute('''
          CREATE TABLE app_state (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
      },
    );
    await legacy.close();

    final upgraded = await AppDatabase.open(databasePath: dbPath);
    await upgraded.close();

    final db = await openDatabase(dbPath);
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_log_entries'",
    );
    expect(tables, isNotEmpty);

    final columns = await db.rawQuery('PRAGMA table_info(sync_log_entries)');
    final names = columns.map((row) => row['name']).toList(growable: false);
    expect(names, containsAll(['level', 'event', 'message', 'asset_id', 'project_id', 'created_at']));
    await db.close();
  });
}
