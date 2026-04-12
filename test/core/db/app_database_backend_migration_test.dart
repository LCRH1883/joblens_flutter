import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('migrates schema from v2 to v3 with backend cloud columns', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_db_backend_migration_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final legacy = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE projects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            notes TEXT NOT NULL DEFAULT '',
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
      },
    );

    final now = DateTime.now().toIso8601String();
    final projectId = await legacy.insert('projects', {
      'name': 'Mapped',
      'notes': '',
      'cover_asset_id': null,
      'created_at': now,
      'updated_at': now,
      'sync_folder_map': '{}',
    });
    await legacy.insert('photo_assets', {
      'id': 'asset-1',
      'local_path': '/tmp/a.jpg',
      'thumb_path': '/tmp/a_thumb.jpg',
      'created_at': now,
      'imported_at': now,
      'project_id': projectId,
      'hash': 'a' * 64,
      'status': AssetStatus.active.name,
      'source_type': AssetSourceType.captured.name,
    });
    await legacy.close();

    final upgraded = await AppDatabase.open(databasePath: dbPath);
    await upgraded.close();

    final db = await openDatabase(dbPath);
    final projectColumns = await db.rawQuery('PRAGMA table_info(projects)');
    final projectColumnNames = projectColumns
        .map((row) => row['name'])
        .toList(growable: false);
    expect(projectColumnNames, contains('remote_project_id'));

    final assetColumns = await db.rawQuery('PRAGMA table_info(photo_assets)');
    final assetColumnNames = assetColumns
        .map((row) => row['name'])
        .toList(growable: false);
    expect(assetColumnNames, contains('remote_asset_id'));
    expect(assetColumnNames, contains('upload_session_id'));
    expect(assetColumnNames, contains('upload_path'));
    expect(assetColumnNames, contains('cloud_state'));
    expect(assetColumnNames, contains('last_sync_error_code'));
    expect(assetColumnNames, contains('hard_delete_due_at'));
    expect(assetColumnNames, contains('purge_requested_at'));

    final row = await db.query(
      'photo_assets',
      columns: ['cloud_state', 'remote_asset_id', 'upload_session_id'],
      where: 'id = ?',
      whereArgs: ['asset-1'],
      limit: 1,
    );
    expect(row, isNotEmpty);
    expect(row.first['cloud_state'], AssetCloudState.localAndCloud);
    expect(row.first['remote_asset_id'], isNull);
    expect(row.first['upload_session_id'], isNull);

    final assetIndexes = await db.rawQuery('PRAGMA index_list(photo_assets)');
    final assetIndexNames = assetIndexes
        .map((row) => row['name'])
        .toList(growable: false);
    expect(assetIndexNames, contains('idx_assets_remote_asset_id'));

    final projectIndexes = await db.rawQuery('PRAGMA index_list(projects)');
    final projectIndexNames = projectIndexes
        .map((row) => row['name'])
        .toList(growable: false);
    expect(projectIndexNames, contains('idx_projects_remote_project_id'));

    await db.close();
  });
}
