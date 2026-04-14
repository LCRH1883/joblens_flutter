import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_provider.dart';
import '../models/app_launch_destination.dart';
import '../models/app_theme_mode.dart';
import '../models/blob_upload_task.dart';
import '../models/camera_metrics.dart';
import '../models/capture_target_preference.dart';
import '../models/entity_sync_record.dart';
import '../models/library_import_mode.dart';
import '../models/photo_asset.dart';
import '../models/project.dart';
import '../models/provider_account.dart';
import '../models/sync_log_entry.dart';
import '../models/sync_job.dart';

enum AssetOutboxState { queued, uploading, failed }

class SyncActivityCounts {
  const SyncActivityCounts({
    required this.metadataQueued,
    required this.metadataFailed,
    required this.uploadQueued,
    required this.uploadUploading,
    required this.uploadFailed,
  });

  final int metadataQueued;
  final int metadataFailed;
  final int uploadQueued;
  final int uploadUploading;
  final int uploadFailed;

  int get queuedCount => metadataQueued + uploadQueued;
  int get uploadingCount => uploadUploading;
  int get failedCount => metadataFailed + uploadFailed;
  int get totalOutstanding => queuedCount + uploadingCount + failedCount;
}

class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;
  static const _uuid = Uuid();
  static const _schemaVersion = 15;

  static Future<AppDatabase> open({String? databasePath}) async {
    final resolvedPath = databasePath ?? await _defaultDatabasePath();

    final db = await openDatabase(
      resolvedPath,
      version: _schemaVersion,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 9) {
          await _migrateLegacySchema(db);
          return;
        }

        if (oldVersion < 10) {
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN account_identifier TEXT',
          );
        }
        if (oldVersion < 11) {
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN connection_id TEXT',
          );
          await db.execute(
            "ALTER TABLE provider_accounts ADD COLUMN connection_status TEXT NOT NULL DEFAULT 'disconnected'",
          );
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN root_display_name TEXT',
          );
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN root_folder_path TEXT',
          );
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN last_error TEXT',
          );
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN is_active INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS project_provider_mirrors (
              local_project_id INTEGER NOT NULL,
              provider_connection_id TEXT NOT NULL,
              status TEXT NOT NULL,
              provider_folder_id TEXT,
              provider_rev TEXT,
              last_error TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (local_project_id, provider_connection_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS asset_provider_mirrors (
              asset_id TEXT NOT NULL,
              provider_connection_id TEXT NOT NULL,
              status TEXT NOT NULL,
              provider_file_id TEXT,
              remote_path TEXT,
              provider_rev TEXT,
              last_error TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (asset_id, provider_connection_id)
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_project_provider_mirrors_connection ON project_provider_mirrors(provider_connection_id, status, updated_at)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_asset_provider_mirrors_connection ON asset_provider_mirrors(provider_connection_id, status, updated_at)',
          );
        }
        if (oldVersion < 12) {
          await db.execute(
            'ALTER TABLE photo_assets ADD COLUMN hard_delete_due_at TEXT',
          );
        }
        if (oldVersion < 13) {
          await db.execute(
            'ALTER TABLE photo_assets ADD COLUMN purge_requested_at TEXT',
          );
        }
        if (oldVersion < 14) {
          await db.execute(
            "ALTER TABLE provider_accounts ADD COLUMN sync_health TEXT NOT NULL DEFAULT 'healthy'",
          );
          await db.execute(
            'ALTER TABLE provider_accounts ADD COLUMN open_conflict_count INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 15) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS camera_session_metrics (
              session_id TEXT PRIMARY KEY,
              platform TEXT NOT NULL,
              opened_at TEXT NOT NULL,
              preview_ready_at TEXT,
              closed_at TEXT,
              open_to_preview_ready_ms INTEGER,
              last_capture_local_save_ms INTEGER,
              last_lens_switch_ms INTEGER,
              last_target_picker_open_ms INTEGER,
              capture_attempt_count INTEGER NOT NULL DEFAULT 0,
              capture_local_save_count INTEGER NOT NULL DEFAULT 0,
              capture_success_count INTEGER NOT NULL DEFAULT 0,
              hard_failure_count INTEGER NOT NULL DEFAULT 0,
              abandoned INTEGER NOT NULL DEFAULT 0,
              close_reason TEXT
            )
          ''');
        }
      },
    );

    return AppDatabase._(db);
  }

  static Future<String> _defaultDatabasePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'joblens.db');
  }

  Future<void> close() async => _db.close();

  int _nextLocalSeq() => DateTime.now().microsecondsSinceEpoch;

  static Future<void> _migrateLegacySchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
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
      CREATE TABLE IF NOT EXISTS photo_assets (
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
        exists_in_phone_storage INTEGER NOT NULL DEFAULT 0,
        last_sync_error_code TEXT,
        deleted_at TEXT,
        hard_delete_due_at TEXT,
        purge_requested_at TEXT,
        remote_rev INTEGER,
        local_seq INTEGER NOT NULL DEFAULT 0,
        dirty_fields TEXT NOT NULL DEFAULT '[]',
        upload_generation INTEGER NOT NULL DEFAULT 1,
        ingest_state TEXT NOT NULL DEFAULT 'ready',
        FOREIGN KEY(project_id) REFERENCES projects(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS provider_accounts (
        id TEXT PRIMARY KEY,
        provider_type TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        connection_id TEXT,
        account_identifier TEXT,
        connection_status TEXT NOT NULL DEFAULT 'disconnected',
        token_state TEXT NOT NULL,
        connected_at TEXT,
        root_display_name TEXT,
        root_folder_path TEXT,
        last_error TEXT,
        is_active INTEGER NOT NULL DEFAULT 0,
        sync_health TEXT NOT NULL DEFAULT 'healthy',
        open_conflict_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'notes',
      columnSql: "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'start_date',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'remote_project_id',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'deleted_at',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'remote_rev',
      columnSql: 'INTEGER',
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'local_seq',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      tableName: 'projects',
      columnName: 'dirty_fields',
      columnSql: "TEXT NOT NULL DEFAULT '[]'",
    );

    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'remote_asset_id',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'remote_provider',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'remote_file_id',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'upload_session_id',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'upload_path',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'cloud_state',
      columnSql: "TEXT NOT NULL DEFAULT 'local_and_cloud'",
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'exists_in_phone_storage',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'last_sync_error_code',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'deleted_at',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'hard_delete_due_at',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'purge_requested_at',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'remote_rev',
      columnSql: 'INTEGER',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'local_seq',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'dirty_fields',
      columnSql: "TEXT NOT NULL DEFAULT '[]'",
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'upload_generation',
      columnSql: 'INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(
      db,
      tableName: 'photo_assets',
      columnName: 'ingest_state',
      columnSql: "TEXT NOT NULL DEFAULT 'ready'",
    );

    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'connection_id',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'account_identifier',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'connection_status',
      columnSql: "TEXT NOT NULL DEFAULT 'disconnected'",
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'root_display_name',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'root_folder_path',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'last_error',
      columnSql: 'TEXT',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'is_active',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'sync_health',
      columnSql: "TEXT NOT NULL DEFAULT 'healthy'",
    );
    await _ensureColumn(
      db,
      tableName: 'provider_accounts',
      columnName: 'open_conflict_count',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS entity_sync (
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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS blob_upload (
        asset_id TEXT NOT NULL,
        upload_generation INTEGER NOT NULL,
        local_uri TEXT NOT NULL,
        state TEXT NOT NULL,
        bytes_sent INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        leased_until TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (asset_id, upload_generation),
        FOREIGN KEY(asset_id) REFERENCES photo_assets(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_log_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL,
        event TEXT NOT NULL,
        message TEXT NOT NULL,
        asset_id TEXT,
        project_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS camera_session_metrics (
        session_id TEXT PRIMARY KEY,
        platform TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        preview_ready_at TEXT,
        closed_at TEXT,
        open_to_preview_ready_ms INTEGER,
        last_capture_local_save_ms INTEGER,
        last_lens_switch_ms INTEGER,
        last_target_picker_open_ms INTEGER,
        capture_attempt_count INTEGER NOT NULL DEFAULT 0,
        capture_local_save_count INTEGER NOT NULL DEFAULT 0,
        capture_success_count INTEGER NOT NULL DEFAULT 0,
        hard_failure_count INTEGER NOT NULL DEFAULT 0,
        abandoned INTEGER NOT NULL DEFAULT 0,
        close_reason TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS project_provider_mirrors (
        local_project_id INTEGER NOT NULL,
        provider_connection_id TEXT NOT NULL,
        status TEXT NOT NULL,
        provider_folder_id TEXT,
        provider_rev TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (local_project_id, provider_connection_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS asset_provider_mirrors (
        asset_id TEXT NOT NULL,
        provider_connection_id TEXT NOT NULL,
        status TEXT NOT NULL,
        provider_file_id TEXT,
        remote_path TEXT,
        provider_rev TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (asset_id, provider_connection_id)
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_assets_project ON photo_assets(project_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_assets_created ON photo_assets(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_assets_remote_asset_id ON photo_assets(remote_asset_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_projects_remote_project_id ON projects(remote_project_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entity_sync_next_attempt ON entity_sync(next_attempt_at, updated_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_blob_upload_state ON blob_upload(state, updated_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_project_provider_mirrors_connection ON project_provider_mirrors(provider_connection_id, status, updated_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_asset_provider_mirrors_connection ON asset_provider_mirrors(provider_connection_id, status, updated_at)',
    );
  }

  static Future<void> _ensureColumn(
    Database db, {
    required String tableName,
    required String columnName,
    required String columnSql,
  }) async {
    final columns = await db.rawQuery('PRAGMA table_info($tableName)');
    final existingNames = columns
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
    if (existingNames.contains(columnName)) {
      return;
    }
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN $columnName $columnSql',
    );
  }

  static Future<void> _createSchema(Database db) async {
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
        exists_in_phone_storage INTEGER NOT NULL DEFAULT 0,
        last_sync_error_code TEXT,
        deleted_at TEXT,
        hard_delete_due_at TEXT,
        purge_requested_at TEXT,
        remote_rev INTEGER,
        local_seq INTEGER NOT NULL DEFAULT 0,
        dirty_fields TEXT NOT NULL DEFAULT '[]',
        upload_generation INTEGER NOT NULL DEFAULT 1,
        ingest_state TEXT NOT NULL DEFAULT 'ready',
        FOREIGN KEY(project_id) REFERENCES projects(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE provider_accounts (
        id TEXT PRIMARY KEY,
        provider_type TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        connection_id TEXT,
        account_identifier TEXT,
        connection_status TEXT NOT NULL,
        token_state TEXT NOT NULL,
        connected_at TEXT
        ,
        root_display_name TEXT,
        root_folder_path TEXT,
        last_error TEXT,
        is_active INTEGER NOT NULL DEFAULT 0,
        sync_health TEXT NOT NULL DEFAULT 'healthy',
        open_conflict_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE project_provider_mirrors (
        local_project_id INTEGER NOT NULL,
        provider_connection_id TEXT NOT NULL,
        status TEXT NOT NULL,
        provider_folder_id TEXT,
        provider_rev TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (local_project_id, provider_connection_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE asset_provider_mirrors (
        asset_id TEXT NOT NULL,
        provider_connection_id TEXT NOT NULL,
        status TEXT NOT NULL,
        provider_file_id TEXT,
        remote_path TEXT,
        provider_rev TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (asset_id, provider_connection_id)
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

    await db.execute('''
      CREATE TABLE blob_upload (
        asset_id TEXT NOT NULL,
        upload_generation INTEGER NOT NULL,
        local_uri TEXT NOT NULL,
        state TEXT NOT NULL,
        bytes_sent INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        leased_until TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (asset_id, upload_generation),
        FOREIGN KEY(asset_id) REFERENCES photo_assets(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_log_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level TEXT NOT NULL,
        event TEXT NOT NULL,
        message TEXT NOT NULL,
        asset_id TEXT,
        project_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE camera_session_metrics (
        session_id TEXT PRIMARY KEY,
        platform TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        preview_ready_at TEXT,
        closed_at TEXT,
        open_to_preview_ready_ms INTEGER,
        last_capture_local_save_ms INTEGER,
        last_lens_switch_ms INTEGER,
        last_target_picker_open_ms INTEGER,
        capture_attempt_count INTEGER NOT NULL DEFAULT 0,
        capture_local_save_count INTEGER NOT NULL DEFAULT 0,
        capture_success_count INTEGER NOT NULL DEFAULT 0,
        hard_failure_count INTEGER NOT NULL DEFAULT 0,
        abandoned INTEGER NOT NULL DEFAULT 0,
        close_reason TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_assets_project ON photo_assets(project_id)',
    );
    await db.execute(
      'CREATE INDEX idx_assets_created ON photo_assets(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_assets_remote_asset_id ON photo_assets(remote_asset_id)',
    );
    await db.execute(
      'CREATE INDEX idx_projects_remote_project_id ON projects(remote_project_id)',
    );
    await db.execute(
      'CREATE INDEX idx_entity_sync_next_attempt ON entity_sync(next_attempt_at, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_blob_upload_state ON blob_upload(state, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_project_provider_mirrors_connection ON project_provider_mirrors(provider_connection_id, status, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_asset_provider_mirrors_connection ON asset_provider_mirrors(provider_connection_id, status, updated_at)',
    );
  }

  Future<int> normalizeAssetMediaPaths(String currentMediaRootPath) async {
    final rows = await _db.query(
      'photo_assets',
      columns: ['id', 'local_path', 'thumb_path'],
      where: 'local_path != ? OR thumb_path != ?',
      whereArgs: ['', ''],
    );
    var updatedCount = 0;

    for (final row in rows) {
      final assetId = row['id']! as String;
      final currentLocalPath = row['local_path']! as String;
      final currentThumbPath = row['thumb_path']! as String;
      final normalizedLocalPath = rebaseMediaPath(
        currentLocalPath,
        currentMediaRootPath,
      );
      final normalizedThumbPath = rebaseMediaPath(
        currentThumbPath,
        currentMediaRootPath,
      );
      if (normalizedLocalPath == currentLocalPath &&
          normalizedThumbPath == currentThumbPath) {
        continue;
      }

      await _db.update(
        'photo_assets',
        {'local_path': normalizedLocalPath, 'thumb_path': normalizedThumbPath},
        where: 'id = ?',
        whereArgs: [assetId],
      );
      updatedCount += 1;
    }

    return updatedCount;
  }

  Future<String?> getStoredAuthUserId() async {
    final rows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['auth_user_id'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final value = rows.first['value'] as String?;
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value;
  }

  Future<void> setStoredAuthUserId(String? userId) async {
    if (userId == null || userId.trim().isEmpty) {
      await _db.delete(
        'app_state',
        where: 'key = ?',
        whereArgs: ['auth_user_id'],
      );
      return;
    }

    await _db.insert('app_state', {
      'key': 'auth_user_id',
      'value': userId.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ProjectSortMode> getProjectSortMode() async {
    final rows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['project_sort_mode'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return ProjectSortMode.name;
    }
    return ProjectSortMode.fromStorage(rows.first['value'] as String?);
  }

  Future<void> setProjectSortMode(ProjectSortMode mode) async {
    await _db.insert('app_state', {
      'key': 'project_sort_mode',
      'value': mode.storageValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<AppThemeMode> getAppThemeMode() async {
    final rows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['app_theme_mode'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return AppThemeMode.system;
    }
    return AppThemeMode.fromStorage(rows.first['value'] as String?);
  }

  Future<void> setAppThemeMode(AppThemeMode mode) async {
    await _db.insert('app_state', {
      'key': 'app_theme_mode',
      'value': mode.storageValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<AppLaunchDestination?> getStoredAppLaunchDestination() async {
    final rows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['app_launch_destination'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return AppLaunchDestination.fromStorage(rows.first['value'] as String?);
  }

  Future<AppLaunchDestination> getAppLaunchDestination() async {
    return await getStoredAppLaunchDestination() ?? AppLaunchDestination.camera;
  }

  Future<void> setAppLaunchDestination(AppLaunchDestination destination) async {
    await _db.insert('app_state', {
      'key': 'app_launch_destination',
      'value': destination.storageValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<LibraryImportMode> getLibraryImportMode() async {
    final rows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['library_import_mode'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return LibraryImportMode.copy;
    }
    return LibraryImportMode.fromStorage(rows.first['value'] as String?);
  }

  Future<void> setLibraryImportMode(LibraryImportMode mode) async {
    await _db.insert('app_state', {
      'key': 'library_import_mode',
      'value': mode.storageValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<CaptureTargetPreference> getCaptureTargetPreference() async {
    final modeRows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['capture_target_mode'],
      limit: 1,
    );
    final fixedRows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['capture_fixed_project_id'],
      limit: 1,
    );
    final lastUsedRows = await _db.query(
      'app_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['capture_last_used_project_id'],
      limit: 1,
    );

    final legacyLastUsedProjectId = lastUsedRows.isEmpty
        ? null
        : int.tryParse((lastUsedRows.first['value'] as String?) ?? '');
    final storedMode = CaptureTargetMode.fromStorage(
      modeRows.isEmpty ? null : modeRows.first['value'] as String?,
    );

    return CaptureTargetPreference(
      mode: switch (storedMode) {
        CaptureTargetMode.lastUsed when legacyLastUsedProjectId != null =>
          CaptureTargetMode.fixedProject,
        CaptureTargetMode.lastUsed => CaptureTargetMode.inbox,
        _ => storedMode,
      },
      fixedProjectId: switch (storedMode) {
        CaptureTargetMode.lastUsed => legacyLastUsedProjectId,
        _ =>
          fixedRows.isEmpty
              ? null
              : int.tryParse((fixedRows.first['value'] as String?) ?? ''),
      },
      lastUsedProjectId: legacyLastUsedProjectId,
    );
  }

  Future<void> setCaptureTargetMode(CaptureTargetMode mode) async {
    await _db.insert('app_state', {
      'key': 'capture_target_mode',
      'value': mode.storageValue,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setCaptureFixedProjectId(int? projectId) async {
    if (projectId == null) {
      await _db.delete(
        'app_state',
        where: 'key = ?',
        whereArgs: ['capture_fixed_project_id'],
      );
      return;
    }
    await _db.insert('app_state', {
      'key': 'capture_fixed_project_id',
      'value': projectId.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setCaptureLastUsedProjectId(int? projectId) async {
    if (projectId == null) {
      await _db.delete(
        'app_state',
        where: 'key = ?',
        whereArgs: ['capture_last_used_project_id'],
      );
      return;
    }
    await _db.insert('app_state', {
      'key': 'capture_last_used_project_id',
      'value': projectId.toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearUserScopedData() async {
    await _db.transaction((txn) async {
      await txn.delete('entity_sync');
      await txn.delete('blob_upload');
      await txn.delete('sync_state');
      await txn.delete('sync_log_entries');
      await txn.delete('photo_assets');
      await txn.delete('projects');
      await txn.delete('provider_accounts');
      await txn.delete(
        'app_state',
        where: 'key IN (?, ?)',
        whereArgs: ['capture_fixed_project_id', 'capture_last_used_project_id'],
      );
    });
  }

  Future<int> ensureDefaultProject() async {
    final now = DateTime.now().toIso8601String();
    final existing = await _db.query(
      'projects',
      where: 'name = ?',
      whereArgs: ['Inbox'],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id']! as int;
    }

    return _db.insert('projects', {
      'name': 'Inbox',
      'notes': '',
      'start_date': null,
      'remote_project_id': null,
      'cover_asset_id': null,
      'created_at': now,
      'updated_at': now,
      'sync_folder_map': '{}',
      'deleted_at': null,
      'remote_rev': null,
      'local_seq': 0,
      'dirty_fields': '[]',
    });
  }

  Future<List<Project>> getProjects({bool includeDeleted = false}) async {
    final rows = await _db.query(
      'projects',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(Project.fromMap).toList();
  }

  Future<int?> getLocalProjectIdByRemoteId(String remoteProjectId) async {
    final rows = await _db.query(
      'projects',
      columns: ['id'],
      where: 'remote_project_id = ?',
      whereArgs: [remoteProjectId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['id'] as int;
  }

  Future<int?> getLocalProjectIdByName(
    String name, {
    bool includeDeleted = true,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final rows = await _db.query(
      'projects',
      columns: ['id'],
      where: includeDeleted ? 'name = ?' : 'name = ? AND deleted_at IS NULL',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['id'] as int;
  }

  Future<Project?> getProjectById(
    int projectId, {
    bool includeDeleted = true,
  }) async {
    final rows = await _db.query(
      'projects',
      where: includeDeleted ? 'id = ?' : 'id = ? AND deleted_at IS NULL',
      whereArgs: [projectId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return Project.fromMap(rows.first);
  }

  Future<int> createProject(String name, {DateTime? startDate}) async {
    final now = DateTime.now().toIso8601String();
    final localSeq = _nextLocalSeq();
    return _db.transaction((txn) async {
      final existing = await txn.query(
        'projects',
        columns: ['id'],
        where: 'name = ? AND deleted_at IS NULL',
        whereArgs: [name],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return existing.first['id']! as int;
      }
      final id = await txn.insert('projects', {
        'name': name,
        'notes': '',
        'start_date': startDate?.toIso8601String(),
        'remote_project_id': null,
        'cover_asset_id': null,
        'created_at': now,
        'updated_at': now,
        'sync_folder_map': '{}',
        'deleted_at': null,
        'remote_rev': null,
        'local_seq': localSeq,
        'dirty_fields': '["name","start_date"]',
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.project,
        entityId: id.toString(),
        dirtyFields: const ['name', 'start_date'],
        baseRemoteRev: null,
        localSeq: localSeq,
      );
      return id;
    });
  }

  Future<void> updateProjectRemoteId(
    int projectId,
    String? remoteProjectId,
  ) async {
    await _db.update(
      'projects',
      {
        'remote_project_id': remoteProjectId,
        'updated_at': DateTime.now().toIso8601String(),
        'dirty_fields': '[]',
      },
      where: 'id = ?',
      whereArgs: [projectId],
    );
  }

  Future<void> markProjectSynced(
    int projectId, {
    String? remoteProjectId,
    int? remoteRev,
    bool clearDirtyFields = true,
  }) async {
    await _db.update(
      'projects',
      {
        ...?remoteProjectId == null
            ? null
            : {'remote_project_id': remoteProjectId},
        ...?remoteRev == null ? null : {'remote_rev': remoteRev},
        if (clearDirtyFields) 'dirty_fields': '[]',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [projectId],
    );
  }

  Future<void> updateProjectMetadata(
    int projectId, {
    required String name,
    DateTime? startDate,
  }) async {
    final now = DateTime.now().toIso8601String();
    final localSeq = _nextLocalSeq();
    await _db.transaction((txn) async {
      final current = await txn.query(
        'projects',
        columns: ['remote_rev'],
        where: 'id = ?',
        whereArgs: [projectId],
        limit: 1,
      );
      await txn.update(
        'projects',
        {
          'name': name,
          'start_date': startDate?.toIso8601String(),
          'updated_at': now,
          'local_seq': localSeq,
          'dirty_fields': '["name","start_date"]',
        },
        where: 'id = ?',
        whereArgs: [projectId],
      );
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.project,
        entityId: projectId.toString(),
        dirtyFields: const ['name', 'start_date'],
        baseRemoteRev: current.isEmpty
            ? null
            : current.first['remote_rev'] as int?,
        localSeq: localSeq,
      );
    });
  }

  Future<int> upsertRemoteProjectSnapshot({
    required String remoteProjectId,
    required String name,
    required int? remoteRev,
    bool deleted = false,
  }) async {
    final existingId = await getLocalProjectIdByRemoteId(remoteProjectId);
    final now = DateTime.now().toIso8601String();
    if (existingId != null) {
      await _db.update(
        'projects',
        {
          'name': name,
          'remote_project_id': remoteProjectId,
          'remote_rev': remoteRev,
          'deleted_at': deleted ? now : null,
          'dirty_fields': '[]',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [existingId],
      );
      return existingId;
    }

    final existingByNameId = await getLocalProjectIdByName(name);
    if (existingByNameId != null) {
      await _db.update(
        'projects',
        {
          'name': name,
          'remote_project_id': remoteProjectId,
          'remote_rev': remoteRev,
          'deleted_at': deleted ? now : null,
          'dirty_fields': '[]',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [existingByNameId],
      );
      return existingByNameId;
    }

    return _db.insert('projects', {
      'name': name,
      'notes': '',
      'start_date': null,
      'remote_project_id': remoteProjectId,
      'cover_asset_id': null,
      'created_at': now,
      'updated_at': now,
      'sync_folder_map': '{}',
      'deleted_at': deleted ? now : null,
      'remote_rev': remoteRev,
      'local_seq': 0,
      'dirty_fields': '[]',
    });
  }

  Future<void> updateProjectNotes(int projectId, String notes) async {
    await _db.update(
      'projects',
      {'notes': notes, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [projectId],
    );
  }

  Future<void> deleteProject(
    int projectId, {
    required int fallbackProjectId,
  }) async {
    await _db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      final projectRows = await txn.query(
        'projects',
        columns: ['remote_rev'],
        where: 'id = ?',
        whereArgs: [projectId],
        limit: 1,
      );
      final movedAssetRows = await txn.query(
        'photo_assets',
        columns: ['id', 'remote_rev'],
        where: 'project_id = ? AND status = ?',
        whereArgs: [projectId, AssetStatus.active.name],
      );
      final localSeq = _nextLocalSeq();
      await txn.update(
        'photo_assets',
        {
          'project_id': fallbackProjectId,
          'local_seq': localSeq,
          'dirty_fields': '["project_id"]',
        },
        where: 'project_id = ?',
        whereArgs: [projectId],
      );
      for (final row in movedAssetRows) {
        await _upsertEntitySyncExecutor(
          txn,
          entityType: SyncEntityType.asset,
          entityId: row['id']! as String,
          dirtyFields: const ['project_id'],
          baseRemoteRev: row['remote_rev'] as int?,
          localSeq: localSeq,
        );
      }
      await txn.update(
        'projects',
        {
          'deleted_at': now,
          'updated_at': now,
          'local_seq': localSeq,
          'dirty_fields': '["deleted_at"]',
        },
        where: 'id = ?',
        whereArgs: [projectId],
      );
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.project,
        entityId: projectId.toString(),
        dirtyFields: const ['deleted_at'],
        baseRemoteRev: projectRows.isEmpty
            ? null
            : projectRows.first['remote_rev'] as int?,
        localSeq: localSeq,
      );
    });
  }

  Future<void> upsertAsset(PhotoAsset asset) async {
    final localSeq = asset.localSeq == 0 ? _nextLocalSeq() : asset.localSeq;
    final storedAsset = asset.copyWith(
      localSeq: localSeq,
      dirtyFields: const [],
      deletedAt: null,
      uploadGeneration: asset.uploadGeneration <= 0
          ? 1
          : asset.uploadGeneration,
    );
    await _db.transaction((txn) async {
      await txn.insert(
        'photo_assets',
        storedAsset.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'projects',
        {
          'cover_asset_id': asset.id,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [asset.projectId],
      );
      await _upsertBlobUploadExecutor(
        txn,
        assetId: storedAsset.id,
        uploadGeneration: storedAsset.uploadGeneration,
        localUri: storedAsset.localPath,
      );
    });
  }

  Future<void> insertPendingAssetShell(PhotoAsset asset) async {
    await _db.transaction((txn) async {
      await txn.insert(
        'photo_assets',
        asset.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'projects',
        {
          'cover_asset_id': asset.id,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [asset.projectId],
      );
    });
  }

  Future<void> upsertCloudOnlyAsset({
    required String localAssetId,
    required int projectId,
    required String remoteAssetId,
    String? remoteProvider,
    String? remoteFileId,
    String? remotePath,
    required String sha256,
    required DateTime createdAt,
    DateTime? purgeRequestedAt,
    String? cloudState,
    bool deleted = false,
  }) async {
    final now = DateTime.now();
    final status = deleted ? AssetStatus.deleted : AssetStatus.active;
    await _db.insert('photo_assets', {
      'id': localAssetId,
      'local_path': '',
      'thumb_path': '',
      'created_at': createdAt.toIso8601String(),
      'imported_at': now.toIso8601String(),
      'project_id': projectId,
      'hash': sha256,
      'status': status.name,
      'source_type': AssetSourceType.imported.name,
      'remote_asset_id': remoteAssetId,
      'remote_provider': remoteProvider,
      'remote_file_id': remoteFileId,
      'upload_session_id': null,
      'upload_path': remotePath,
      'cloud_state':
          cloudState ??
          (deleted ? AssetCloudState.deleted : AssetCloudState.cloudOnly),
      'exists_in_phone_storage': 0,
      'deleted_at': deleted ? createdAt.toIso8601String() : null,
      'hard_delete_due_at': null,
      'purge_requested_at': purgeRequestedAt?.toIso8601String(),
      'remote_rev': null,
      'local_seq': 0,
      'dirty_fields': '[]',
      'upload_generation': 1,
      'ingest_state': AssetIngestState.ready.name,
      'last_sync_error_code': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> applyRemoteAssetSnapshot({
    required String localAssetId,
    required int projectId,
    required String remoteAssetId,
    required String sha256,
    required DateTime createdAt,
    required int? remoteRev,
    String? filename,
    String? remoteProvider,
    String? remoteFileId,
    String? remotePath,
    DateTime? softDeletedAt,
    DateTime? hardDeleteDueAt,
    DateTime? purgeRequestedAt,
    String? cloudState,
    bool deleted = false,
  }) async {
    final existing = await getAssetById(localAssetId);
    if (existing == null) {
      await upsertCloudOnlyAsset(
        localAssetId: localAssetId,
        projectId: projectId,
        remoteAssetId: remoteAssetId,
        remoteProvider: remoteProvider,
        remoteFileId: remoteFileId,
        remotePath: remotePath ?? filename,
        sha256: sha256,
        createdAt: createdAt,
        purgeRequestedAt: purgeRequestedAt,
        cloudState: cloudState,
        deleted: deleted,
      );
      await _db.update(
        'photo_assets',
        {
          'remote_rev': remoteRev,
          'dirty_fields': '[]',
          'purge_requested_at': purgeRequestedAt?.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [localAssetId],
      );
      return;
    }

    await _db.update(
      'photo_assets',
      {
        'project_id': projectId,
        'remote_asset_id': remoteAssetId,
        'remote_provider': remoteProvider,
        'remote_file_id': remoteFileId,
        'upload_path': remotePath,
        'cloud_state':
            cloudState ??
            (deleted
                ? AssetCloudState.deleted
                : existing.localPath.isEmpty
                ? AssetCloudState.cloudOnly
                : AssetCloudState.localAndCloud),
        'status': deleted ? AssetStatus.deleted.name : AssetStatus.active.name,
        'deleted_at': deleted
            ? (softDeletedAt ?? DateTime.now()).toIso8601String()
            : null,
        'hard_delete_due_at': deleted
            ? hardDeleteDueAt?.toIso8601String()
            : null,
        'purge_requested_at': purgeRequestedAt?.toIso8601String(),
        'remote_rev': remoteRev,
        'dirty_fields': '[]',
        'last_sync_error_code': null,
      },
      where: 'id = ?',
      whereArgs: [localAssetId],
    );
  }

  Future<List<PhotoAsset>> getAssets({
    int? projectId,
    bool includeDeleted = false,
  }) async {
    final whereParts = <String>[];
    final args = <Object?>[];

    if (!includeDeleted) {
      whereParts.add('status = ?');
      args.add(AssetStatus.active.name);
    }
    if (projectId != null) {
      whereParts.add('project_id = ?');
      args.add(projectId);
    }

    final rows = await _db.query(
      'photo_assets',
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC',
    );

    return rows.map(PhotoAsset.fromMap).toList();
  }

  Future<List<PhotoAsset>> getDeletedAssets() async {
    final rows = await _db.query(
      'photo_assets',
      where: 'status = ? AND purge_requested_at IS NULL',
      whereArgs: [AssetStatus.deleted.name],
      orderBy: 'deleted_at DESC, created_at DESC',
    );
    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<List<PhotoAsset>> getAssetsByRemoteId(String remoteAssetId) async {
    final rows = await _db.query(
      'photo_assets',
      where: 'remote_asset_id = ?',
      whereArgs: [remoteAssetId],
      orderBy: 'created_at DESC',
    );
    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<List<PhotoAsset>> getAssetsByHashValue(String hash) async {
    final rows = await _db.query(
      'photo_assets',
      where: 'hash = ?',
      whereArgs: [hash],
      orderBy: 'created_at DESC',
    );
    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<void> restoreAsset(String assetId) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'photo_assets',
        columns: ['local_path'],
        where: 'id = ?',
        whereArgs: [assetId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final localPath = (rows.first['local_path'] as String?) ?? '';
      await txn.update(
        'photo_assets',
        {
          'status': AssetStatus.active.name,
          'deleted_at': null,
          'hard_delete_due_at': null,
          'purge_requested_at': null,
          'cloud_state': localPath.trim().isEmpty
              ? AssetCloudState.cloudOnly
              : AssetCloudState.localOnly,
          'last_sync_error_code': null,
          'dirty_fields': '[]',
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
    });
  }

  Future<void> markAssetPurgeRequested(
    String assetId, {
    DateTime? requestedAt,
  }) async {
    await _db.update(
      'photo_assets',
      {'purge_requested_at': (requestedAt ?? DateTime.now()).toIso8601String()},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> clearAssetPurgeRequested(String assetId) async {
    await _db.update(
      'photo_assets',
      {'purge_requested_at': null},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<List<PhotoAsset>> getRemoteLinkedAssets({
    bool includeDeleted = true,
  }) async {
    final whereParts = <String>["TRIM(COALESCE(remote_asset_id, '')) != ''"];
    final whereArgs = <Object?>[];
    if (!includeDeleted) {
      whereParts.add('status = ?');
      whereArgs.add(AssetStatus.active.name);
    }
    final rows = await _db.query(
      'photo_assets',
      where: whereParts.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'created_at DESC',
    );
    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<List<AssetIntegrityIssue>> scanAssetIntegrityIssues() async {
    final issues = <AssetIntegrityIssue>[];

    final duplicateRemoteIdRows = await _db.rawQuery('''
      SELECT remote_asset_id, COUNT(*) AS cnt
      FROM photo_assets
      WHERE TRIM(COALESCE(remote_asset_id, '')) != ''
      GROUP BY remote_asset_id
      HAVING COUNT(*) > 1
      ''');
    for (final row in duplicateRemoteIdRows) {
      issues.add(
        AssetIntegrityIssue(
          kind: AssetIntegrityIssueKind.duplicateRemoteAssetId,
          value: row['remote_asset_id']! as String,
          count: (row['cnt'] as int?) ?? 0,
        ),
      );
    }

    final duplicateHashRows = await _db.rawQuery(
      '''
      SELECT hash, COUNT(*) AS cnt
      FROM photo_assets
      WHERE status != ?
        AND LENGTH(hash) = 64
        AND TRIM(COALESCE(remote_asset_id, '')) != ''
      GROUP BY hash
      HAVING COUNT(*) > 1
      ''',
      [AssetStatus.deleted.name],
    );
    for (final row in duplicateHashRows) {
      issues.add(
        AssetIntegrityIssue(
          kind: AssetIntegrityIssueKind.duplicateRemoteHash,
          value: row['hash']! as String,
          count: (row['cnt'] as int?) ?? 0,
        ),
      );
    }

    final inconsistentDeletedRows = await _db.rawQuery(
      '''
      SELECT id
      FROM photo_assets
      WHERE (status = ? AND deleted_at IS NULL)
         OR (status = ? AND deleted_at IS NOT NULL)
      ''',
      [AssetStatus.deleted.name, AssetStatus.active.name],
    );
    for (final row in inconsistentDeletedRows) {
      issues.add(
        AssetIntegrityIssue(
          kind: AssetIntegrityIssueKind.inconsistentDeletedState,
          value: row['id']! as String,
          count: 1,
        ),
      );
    }

    return issues;
  }

  Future<List<PhotoAsset>> getDeletedAssetsPendingRemoteDelete() async {
    final rows = await _db.query(
      'photo_assets',
      where:
          'status = ? AND remote_asset_id IS NOT NULL AND TRIM(remote_asset_id) != ?',
      whereArgs: [AssetStatus.deleted.name, ''],
      orderBy: 'created_at ASC',
    );

    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    await _db.transaction((txn) async {
      final current = await txn.query(
        'photo_assets',
        columns: ['remote_rev'],
        where: 'id = ?',
        whereArgs: [assetId],
        limit: 1,
      );
      final localSeq = _nextLocalSeq();
      await txn.update(
        'photo_assets',
        {
          'project_id': projectId,
          'local_seq': localSeq,
          'dirty_fields': '["project_id"]',
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
      await txn.update(
        'projects',
        {'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [projectId],
      );
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.asset,
        entityId: assetId,
        dirtyFields: const ['project_id'],
        baseRemoteRev: current.isEmpty
            ? null
            : current.first['remote_rev'] as int?,
        localSeq: localSeq,
      );
    });
  }

  Future<void> softDeleteAsset(String assetId) async {
    await _db.transaction((txn) async {
      final currentRows = await txn.query(
        'photo_assets',
        columns: ['remote_rev', 'upload_generation'],
        where: 'id = ?',
        whereArgs: [assetId],
        limit: 1,
      );
      final current = currentRows.isEmpty ? null : currentRows.first;
      final localSeq = _nextLocalSeq();
      await txn.update(
        'photo_assets',
        {
          'status': AssetStatus.deleted.name,
          'deleted_at': DateTime.now().toIso8601String(),
          'cloud_state': AssetCloudState.deleted,
          'last_sync_error_code': null,
          'local_seq': localSeq,
          'dirty_fields': '["deleted_at","status"]',
          'upload_generation':
              ((current?['upload_generation'] as int?) ?? 1) + 1,
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
      await txn.delete(
        'blob_upload',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.asset,
        entityId: assetId,
        dirtyFields: const ['deleted_at', 'status'],
        baseRemoteRev: current?['remote_rev'] as int?,
        localSeq: localSeq,
      );
    });
  }

  Future<void> setAssetExistsInPhoneStorage(
    String assetId,
    bool existsInPhoneStorage,
  ) async {
    await _db.update(
      'photo_assets',
      {'exists_in_phone_storage': existsInPhoneStorage ? 1 : 0},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> ensureProviderRows() async {
    await _ensureColumn(
      _db,
      tableName: 'provider_accounts',
      columnName: 'sync_health',
      columnSql: "TEXT NOT NULL DEFAULT 'healthy'",
    );
    await _ensureColumn(
      _db,
      tableName: 'provider_accounts',
      columnName: 'open_conflict_count',
      columnSql: 'INTEGER NOT NULL DEFAULT 0',
    );
    for (final provider in CloudProviderTypeX.userConfigurableProviders) {
      await _db.insert('provider_accounts', {
        'id': _uuid.v4(),
        'provider_type': provider.key,
        'display_name': provider.label,
        'connection_id': null,
        'account_identifier': null,
        'connection_status': ProviderConnectionStatus.disconnected.storageValue,
        'token_state': ProviderTokenState.disconnected.name,
        'connected_at': null,
        'root_display_name': null,
        'root_folder_path': null,
        'last_error': null,
        'is_active': 0,
        'sync_health': 'healthy',
        'open_conflict_count': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await _db.update(
        'provider_accounts',
        {
          'display_name': provider.label,
          'connection_id': null,
          'account_identifier': null,
          'connection_status':
              ProviderConnectionStatus.disconnected.storageValue,
          'connected_at': null,
          'root_display_name': null,
          'root_folder_path': null,
          'last_error': null,
          'is_active': 0,
          'sync_health': 'healthy',
          'open_conflict_count': 0,
        },
        where: 'provider_type = ? AND connection_status = ?',
        whereArgs: [
          provider.key,
          ProviderConnectionStatus.disconnected.storageValue,
        ],
      );
    }
  }

  Future<List<ProviderAccount>> getProviderAccounts() async {
    final rows = await _db.query(
      'provider_accounts',
      orderBy: 'provider_type ASC',
    );
    return rows.map(ProviderAccount.fromMap).toList();
  }

  Future<String?> getActiveProviderConnectionId() async {
    final rows = await _db.query(
      'provider_accounts',
      columns: ['connection_id'],
      where: 'is_active = 1 AND TRIM(COALESCE(connection_id, \'\')) != ?',
      whereArgs: [''],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final connectionId = rows.first['connection_id'] as String?;
    final trimmed = connectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  Future<({String status, String? lastError})?> getAssetProviderMirrorSnapshot({
    required String assetId,
    required String providerConnectionId,
  }) async {
    final rows = await _db.query(
      'asset_provider_mirrors',
      columns: ['status', 'last_error'],
      where: 'asset_id = ? AND provider_connection_id = ?',
      whereArgs: [assetId, providerConnectionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final status = (rows.first['status'] as String?)?.trim();
    if (status == null || status.isEmpty) {
      return null;
    }
    final lastError = (rows.first['last_error'] as String?)?.trim();
    return (status: status, lastError: lastError?.isEmpty ?? true ? null : lastError);
  }

  Future<void> enqueueSyncJob({
    required String assetId,
    required int projectId,
    required CloudProviderType provider,
  }) async {
    if (provider != CloudProviderType.backend) {
      return;
    }
    final asset = await getAssetById(assetId);
    if (asset == null) {
      return;
    }
    final localSeq = _nextLocalSeq();
    await _db.transaction((txn) async {
      await txn.update(
        'photo_assets',
        {
          'project_id': projectId,
          'local_seq': localSeq,
          'dirty_fields': '["project_id"]',
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
      await _upsertEntitySyncExecutor(
        txn,
        entityType: SyncEntityType.asset,
        entityId: assetId,
        dirtyFields: const ['project_id'],
        baseRemoteRev: asset.remoteRev,
        localSeq: localSeq,
      );
    });
  }

  Future<List<SyncJob>> getSyncJobs() async {
    return _buildSyntheticSyncJobs();
  }

  Future<SyncJob?> getSyncJobForAsset({
    required String assetId,
    required CloudProviderType provider,
  }) async {
    if (provider != CloudProviderType.backend) {
      return null;
    }
    final jobs = await _buildSyntheticSyncJobs(assetIds: {assetId});
    return jobs.cast<SyncJob?>().firstWhere(
      (job) => job?.assetId == assetId,
      orElse: () => null,
    );
  }

  Future<void> addSyncLog({
    required SyncLogLevel level,
    required String event,
    required String message,
    String? assetId,
    int? projectId,
  }) async {
    await _db.insert('sync_log_entries', {
      'level': level.name,
      'event': event,
      'message': message,
      'asset_id': assetId,
      'project_id': projectId,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<SyncLogEntry>> getSyncLogs({int limit = 200}) async {
    final rows = await _db.query(
      'sync_log_entries',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(SyncLogEntry.fromMap).toList(growable: false);
  }

  Future<List<SyncLogEntry>> getAllSyncLogs() async {
    final rows = await _db.query(
      'sync_log_entries',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(SyncLogEntry.fromMap).toList(growable: false);
  }

  Future<void> clearSyncLogs() async {
    await _db.delete('sync_log_entries');
  }

  Future<void> upsertCameraSessionOpened({
    required String sessionId,
    required String platform,
    required DateTime openedAt,
  }) async {
    await _db.insert('camera_session_metrics', {
      'session_id': sessionId,
      'platform': platform,
      'opened_at': openedAt.toIso8601String(),
      'abandoned': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markCameraSessionPreviewReady({
    required String sessionId,
    required DateTime previewReadyAt,
    int? openToPreviewReadyMs,
  }) async {
    await _db.update(
      'camera_session_metrics',
      {
        'preview_ready_at': previewReadyAt.toIso8601String(),
        'open_to_preview_ready_ms': openToPreviewReadyMs,
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> incrementCameraSessionCaptureAttempt(String sessionId) async {
    await _db.rawUpdate(
      '''
      UPDATE camera_session_metrics
      SET capture_attempt_count = capture_attempt_count + 1
      WHERE session_id = ?
      ''',
      [sessionId],
    );
  }

  Future<void> incrementCameraSessionCaptureLocalSave(
    String sessionId, {
    int? captureLocalSaveMs,
  }) async {
    await _db.rawUpdate(
      '''
      UPDATE camera_session_metrics
      SET capture_local_save_count = capture_local_save_count + 1,
          last_capture_local_save_ms = ?
      WHERE session_id = ?
      ''',
      [captureLocalSaveMs, sessionId],
    );
  }

  Future<void> incrementCameraSessionCaptureSuccess(String sessionId) async {
    await _db.rawUpdate(
      '''
      UPDATE camera_session_metrics
      SET capture_success_count = capture_success_count + 1
      WHERE session_id = ?
      ''',
      [sessionId],
    );
  }

  Future<void> incrementCameraSessionHardFailure(String sessionId) async {
    await _db.rawUpdate(
      '''
      UPDATE camera_session_metrics
      SET hard_failure_count = hard_failure_count + 1
      WHERE session_id = ?
      ''',
      [sessionId],
    );
  }

  Future<void> updateCameraSessionLensSwitchDuration(
    String sessionId, {
    int? durationMs,
  }) async {
    await _db.update(
      'camera_session_metrics',
      {'last_lens_switch_ms': durationMs},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> updateCameraSessionTargetPickerDuration(
    String sessionId, {
    int? durationMs,
  }) async {
    await _db.update(
      'camera_session_metrics',
      {'last_target_picker_open_ms': durationMs},
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> completeCameraSession({
    required String sessionId,
    required DateTime closedAt,
    required bool abandoned,
    required String closeReason,
  }) async {
    await _db.update(
      'camera_session_metrics',
      {
        'closed_at': closedAt.toIso8601String(),
        'abandoned': abandoned ? 1 : 0,
        'close_reason': closeReason,
      },
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<CameraSessionMetrics?> getCameraSessionMetrics(String sessionId) async {
    final rows = await _db.query(
      'camera_session_metrics',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return CameraSessionMetrics.fromMap(rows.first);
  }

  Future<CameraMetricsSummary> getCameraMetricsSummary() async {
    final rows = await _db.rawQuery(
      '''
      SELECT
        COUNT(*) AS total_sessions,
        SUM(CASE WHEN preview_ready_at IS NOT NULL THEN 1 ELSE 0 END) AS preview_ready_sessions,
        SUM(CASE WHEN abandoned = 1 THEN 1 ELSE 0 END) AS abandoned_sessions,
        SUM(capture_attempt_count) AS capture_attempts,
        SUM(capture_success_count) AS capture_successes,
        SUM(hard_failure_count) AS hard_failures
      FROM camera_session_metrics
      ''',
    );
    final row = rows.firstOrNull ?? const <String, Object?>{};
    return CameraMetricsSummary(
      totalSessions: _readInt(row['total_sessions']),
      previewReadySessions: _readInt(row['preview_ready_sessions']),
      abandonedSessions: _readInt(row['abandoned_sessions']),
      captureAttempts: _readInt(row['capture_attempts']),
      captureSuccesses: _readInt(row['capture_successes']),
      hardFailures: _readInt(row['hard_failures']),
    );
  }

  Future<String> getOrCreateClientDeviceId() async {
    final existing = await getSyncStateValue('client_device_id');
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }
    final generated = _uuid.v4();
    await setSyncStateValue('client_device_id', generated);
    return generated;
  }

  Future<String?> getBackendDeviceId() =>
      getSyncStateValue('backend_device_id');

  Future<void> setBackendDeviceId(String? value) async {
    await setSyncStateValue('backend_device_id', value);
  }

  Future<int> getLastSyncEventId() async {
    final raw = await getSyncStateValue('last_sync_event_id');
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setLastSyncEventId(int value) async {
    await setSyncStateValue('last_sync_event_id', '$value');
  }

  Future<bool> hasCompletedBootstrap() async {
    final raw = await getSyncStateValue('last_bootstrap_completed_at');
    return raw != null && raw.trim().isNotEmpty;
  }

  Future<void> markBootstrapCompleted() async {
    await setSyncStateValue(
      'last_bootstrap_completed_at',
      DateTime.now().toIso8601String(),
    );
  }

  Future<String?> getSyncStateValue(String key) async {
    final rows = await _db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String?;
  }

  Future<void> setSyncStateValue(String key, String? value) async {
    if (value == null) {
      await _db.delete('sync_state', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db.insert('sync_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<EntitySyncRecord>> getPendingEntitySyncRecords({
    int limit = 100,
  }) async {
    final now = DateTime.now().toIso8601String();
    final rows = await _db.query(
      'entity_sync',
      where:
          '(next_attempt_at IS NULL OR next_attempt_at <= ?) AND (leased_until IS NULL OR leased_until <= ?)',
      whereArgs: [now, now],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return rows.map(EntitySyncRecord.fromMap).toList(growable: false);
  }

  Future<List<EntitySyncRecord>> getAllEntitySyncRecords() async {
    final rows = await _db.query('entity_sync', orderBy: 'updated_at DESC');
    return rows.map(EntitySyncRecord.fromMap).toList(growable: false);
  }

  Future<SyncActivityCounts> getSyncActivityCounts() async {
    final entityRows = await _db.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN TRIM(COALESCE(last_error, '')) = '' THEN 1 ELSE 0 END) AS queued_count,
        SUM(CASE WHEN TRIM(COALESCE(last_error, '')) != '' THEN 1 ELSE 0 END) AS failed_count
      FROM entity_sync
      ''',
    );
    final blobRows = await _db.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN state = ? THEN 1 ELSE 0 END) AS queued_count,
        SUM(CASE WHEN state = ? THEN 1 ELSE 0 END) AS uploading_count,
        SUM(CASE WHEN state = ? THEN 1 ELSE 0 END) AS failed_count
      FROM blob_upload
      ''',
      [
        BlobUploadState.queued.name,
        BlobUploadState.uploading.name,
        BlobUploadState.failed.name,
      ],
    );
    final entity = entityRows.firstOrNull ?? const <String, Object?>{};
    final blob = blobRows.firstOrNull ?? const <String, Object?>{};
    return SyncActivityCounts(
      metadataQueued: _readInt(entity['queued_count']),
      metadataFailed: _readInt(entity['failed_count']),
      uploadQueued: _readInt(blob['queued_count']),
      uploadUploading: _readInt(blob['uploading_count']),
      uploadFailed: _readInt(blob['failed_count']),
    );
  }

  Future<void> upsertEntitySync({
    required SyncEntityType entityType,
    required String entityId,
    required List<String> dirtyFields,
    required int localSeq,
    int? baseRemoteRev,
  }) async {
    await _upsertEntitySyncExecutor(
      _db,
      entityType: entityType,
      entityId: entityId,
      dirtyFields: dirtyFields,
      baseRemoteRev: baseRemoteRev,
      localSeq: localSeq,
    );
  }

  Future<int> backfillEligibleProjectSyncRecords() async {
    return _db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT id, local_seq
        FROM projects
        WHERE deleted_at IS NULL
          AND TRIM(COALESCE(remote_project_id, '')) = ''
          AND CAST(id AS TEXT) NOT IN (
            SELECT entity_id FROM entity_sync WHERE entity_type = ?
          )
      ''',
        [SyncEntityType.project.name],
      );
      for (final row in rows) {
        await _upsertEntitySyncExecutor(
          txn,
          entityType: SyncEntityType.project,
          entityId: (row['id']! as int).toString(),
          dirtyFields: const ['name', 'start_date'],
          baseRemoteRev: null,
          localSeq: (row['local_seq'] as int?) ?? 0,
        );
      }
      return rows.length;
    });
  }

  Future<void> completeEntitySync(
    SyncEntityType entityType,
    String entityId,
  ) async {
    await _db.delete(
      'entity_sync',
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType.name, entityId],
    );
  }

  Future<void> failEntitySync(
    SyncEntityType entityType,
    String entityId,
    String error,
  ) async {
    await _db.update(
      'entity_sync',
      {
        'attempts': 1,
        'leased_until': null,
        'last_error': error,
        'next_attempt_at': DateTime.now()
            .add(const Duration(seconds: 15))
            .toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType.name, entityId],
    );
  }

  Future<void> leaseEntitySync(
    SyncEntityType entityType,
    String entityId, {
    Duration duration = const Duration(seconds: 30),
  }) async {
    await _db.update(
      'entity_sync',
      {
        'leased_until': DateTime.now().add(duration).toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType.name, entityId],
    );
  }

  Future<void> upsertBlobUploadTask({
    required String assetId,
    required int uploadGeneration,
    required String localUri,
  }) async {
    await _upsertBlobUploadExecutor(
      _db,
      assetId: assetId,
      uploadGeneration: uploadGeneration,
      localUri: localUri,
    );
  }

  Future<int> backfillEligibleBlobUploads({
    required String activeProviderConnectionId,
  }) async {
    return _db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT DISTINCT a.id, a.upload_generation, a.local_path
        FROM photo_assets a
        LEFT JOIN asset_provider_mirrors m
          ON m.asset_id = a.id
         AND m.provider_connection_id = ?
        WHERE a.status = ?
          AND a.deleted_at IS NULL
          AND a.ingest_state = ?
          AND TRIM(COALESCE(a.local_path, '')) != ''
          AND a.exists_in_phone_storage = 1
          AND (
            TRIM(COALESCE(a.remote_asset_id, '')) = ''
            OR m.asset_id IS NULL
            OR m.status = 'pending'
            OR (m.status = 'failed' AND COALESCE(m.last_error, '') = 'needs_client_upload')
          )
          AND a.id NOT IN (SELECT asset_id FROM blob_upload)
      ''',
        [
          activeProviderConnectionId,
          AssetStatus.active.name,
          AssetIngestState.ready.name,
        ],
      );
      for (final row in rows) {
        await _upsertBlobUploadExecutor(
          txn,
          assetId: row['id']! as String,
          uploadGeneration: (row['upload_generation'] as int?) ?? 1,
          localUri: row['local_path']! as String,
        );
      }
      return rows.length;
    });
  }

  Future<List<BlobUploadTask>> getPendingBlobUploadTasks({
    int limit = 25,
  }) async {
    final now = DateTime.now().toIso8601String();
    final rows = await _db.query(
      'blob_upload',
      where: '(leased_until IS NULL OR leased_until <= ?) AND state IN (?, ?)',
      whereArgs: [
        now,
        BlobUploadState.queued.name,
        BlobUploadState.failed.name,
      ],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
    return rows.map(BlobUploadTask.fromMap).toList(growable: false);
  }

  Future<List<BlobUploadTask>> getAllBlobUploadTasks() async {
    final rows = await _db.query('blob_upload', orderBy: 'updated_at DESC');
    return rows.map(BlobUploadTask.fromMap).toList(growable: false);
  }

  Future<void> markBlobUploadUploading(
    String assetId,
    int uploadGeneration, {
    Duration duration = const Duration(minutes: 5),
  }) async {
    await _db.update(
      'blob_upload',
      {
        'state': BlobUploadState.uploading.name,
        'leased_until': DateTime.now().add(duration).toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'asset_id = ? AND upload_generation = ?',
      whereArgs: [assetId, uploadGeneration],
    );
  }

  Future<void> failBlobUpload(
    String assetId,
    int uploadGeneration,
    String error,
  ) async {
    await _db.update(
      'blob_upload',
      {
        'state': BlobUploadState.failed.name,
        'leased_until': null,
        'attempts': 1,
        'last_error': error,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'asset_id = ? AND upload_generation = ?',
      whereArgs: [assetId, uploadGeneration],
    );
  }

  Future<void> completeBlobUpload(String assetId, int uploadGeneration) async {
    await _db.delete(
      'blob_upload',
      where: 'asset_id = ? AND upload_generation = ?',
      whereArgs: [assetId, uploadGeneration],
    );
  }

  Future<void> deleteBlobUploadsForAsset(String assetId) async {
    await _db.delete(
      'blob_upload',
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
  }

  Future<bool> updateSyncJob(SyncJob job) async {
    final blob = await _db.query(
      'blob_upload',
      where: 'asset_id = ?',
      whereArgs: [job.assetId],
      limit: 1,
    );
    if (blob.isNotEmpty) {
      if (job.state == SyncJobState.done) {
        final deleted = await _db.delete(
          'blob_upload',
          where: 'asset_id = ? AND updated_at = ?',
          whereArgs: [job.assetId, job.updatedAt.toIso8601String()],
        );
        return deleted > 0;
      }
      final state = switch (job.state) {
        SyncJobState.uploading => BlobUploadState.uploading.name,
        SyncJobState.failed => BlobUploadState.failed.name,
        _ => BlobUploadState.queued.name,
      };
      final updated = await _db.update(
        'blob_upload',
        {
          'state': state,
          'attempts': job.attemptCount,
          'last_error': job.lastError,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'asset_id = ? AND updated_at = ?',
        whereArgs: [job.assetId, job.updatedAt.toIso8601String()],
      );
      return updated > 0;
    }

    final entity = await _db.query(
      'entity_sync',
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [SyncEntityType.asset.name, job.assetId],
      limit: 1,
    );
    if (entity.isEmpty) {
      return false;
    }
    if (job.state == SyncJobState.done) {
      final deleted = await _db.delete(
        'entity_sync',
        where: 'entity_type = ? AND entity_id = ? AND updated_at = ?',
        whereArgs: [
          SyncEntityType.asset.name,
          job.assetId,
          job.updatedAt.toIso8601String(),
        ],
      );
      return deleted > 0;
    }
    final updated = await _db.update(
      'entity_sync',
      {
        'attempts': job.attemptCount,
        'last_error': job.lastError,
        'leased_until': null,
        'next_attempt_at': job.state == SyncJobState.failed
            ? DateTime.now().add(const Duration(seconds: 15)).toIso8601String()
            : DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'entity_type = ? AND entity_id = ? AND updated_at = ?',
      whereArgs: [
        SyncEntityType.asset.name,
        job.assetId,
        job.updatedAt.toIso8601String(),
      ],
    );
    return updated > 0;
  }

  Future<void> setAllFailedToQueued() async {
    await _db.update(
      'blob_upload',
      {
        'state': BlobUploadState.queued.name,
        'last_error': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'state = ?',
      whereArgs: [BlobUploadState.failed.name],
    );
    await _db.update('entity_sync', {
      'last_error': null,
      'next_attempt_at': DateTime.now().toIso8601String(),
      'leased_until': null,
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'last_error IS NOT NULL');
  }

  Future<void> cleanupSyncState() async {
    await _db.transaction((txn) async {
      final now = DateTime.now();
      final nowIso = now.toIso8601String();

      await txn.execute('''
        DELETE FROM blob_upload
        WHERE NOT EXISTS (
          SELECT 1 FROM photo_assets asset WHERE asset.id = blob_upload.asset_id
        )
      ''');
      await txn.execute(
        '''
        DELETE FROM entity_sync
        WHERE entity_type = ?
          AND NOT EXISTS (
            SELECT 1 FROM photo_assets asset WHERE asset.id = entity_sync.entity_id
          )
      ''',
        [SyncEntityType.asset.name],
      );
      await txn.execute(
        '''
        DELETE FROM entity_sync
        WHERE entity_type = ?
          AND NOT EXISTS (
            SELECT 1 FROM projects project WHERE project.id = CAST(entity_sync.entity_id AS INTEGER)
          )
      ''',
        [SyncEntityType.project.name],
      );

      await txn.update(
        'blob_upload',
        {
          'state': BlobUploadState.queued.name,
          'leased_until': null,
          'last_error':
              '[interrupted_upload] Previous upload was interrupted and will be retried.',
          'updated_at': nowIso,
        },
        where: 'state = ? AND leased_until IS NOT NULL AND leased_until <= ?',
        whereArgs: [BlobUploadState.uploading.name, nowIso],
      );

      final blobRows = await txn.rawQuery(
        '''
        SELECT
          blob_upload.asset_id AS asset_id,
          blob_upload.upload_generation AS upload_generation
        FROM blob_upload
        JOIN photo_assets asset ON asset.id = blob_upload.asset_id
        WHERE asset.status = ?
           OR asset.deleted_at IS NOT NULL
           OR TRIM(COALESCE(asset.remote_asset_id, '')) != ''
           OR asset.upload_generation != blob_upload.upload_generation
           OR asset.ingest_state != ?
           OR TRIM(COALESCE(asset.local_path, '')) = ''
      ''',
        [AssetStatus.deleted.name, AssetIngestState.ready.name],
      );
      for (final row in blobRows) {
        await txn.delete(
          'blob_upload',
          where: 'asset_id = ? AND upload_generation = ?',
          whereArgs: [row['asset_id'], row['upload_generation']],
        );
      }

      final assetEntityRows = await txn.rawQuery(
        '''
        SELECT
          entity_sync.entity_id AS entity_id,
          entity_sync.local_seq AS record_local_seq,
          entity_sync.base_remote_rev AS record_base_remote_rev,
          photo_assets.local_seq AS asset_local_seq,
          photo_assets.remote_rev AS asset_remote_rev,
          photo_assets.remote_asset_id AS remote_asset_id,
          photo_assets.deleted_at AS deleted_at,
          photo_assets.dirty_fields AS dirty_fields
        FROM entity_sync
        JOIN photo_assets ON photo_assets.id = entity_sync.entity_id
        WHERE entity_sync.entity_type = ?
      ''',
        [SyncEntityType.asset.name],
      );
      for (final row in assetEntityRows) {
        final entityId = row['entity_id']! as String;
        final remoteAssetId = (row['remote_asset_id'] as String?)?.trim() ?? '';
        final deletedAt = row['deleted_at'] as String?;
        final dirtyFields =
            ((jsonDecode((row['dirty_fields'] as String?) ?? '[]')
                    as List<dynamic>))
                .map((item) => item.toString())
                .toList(growable: false);
        final assetLocalSeq = (row['asset_local_seq'] as int?) ?? 0;
        final recordLocalSeq = (row['record_local_seq'] as int?) ?? 0;

        final shouldDropStaleRecord =
            deletedAt == null && remoteAssetId.isEmpty;
        if (dirtyFields.isEmpty || shouldDropStaleRecord) {
          await txn.delete(
            'entity_sync',
            where: 'entity_type = ? AND entity_id = ?',
            whereArgs: [SyncEntityType.asset.name, entityId],
          );
          continue;
        }

        if (assetLocalSeq > recordLocalSeq) {
          await txn.update(
            'entity_sync',
            {
              'local_seq': assetLocalSeq,
              'base_remote_rev': row['asset_remote_rev'] as int?,
              'dirty_fields': jsonEncode(dirtyFields),
              'last_error': null,
              'leased_until': null,
              'next_attempt_at': nowIso,
              'updated_at': nowIso,
            },
            where: 'entity_type = ? AND entity_id = ?',
            whereArgs: [SyncEntityType.asset.name, entityId],
          );
        }
      }

      final projectEntityRows = await txn.rawQuery(
        '''
        SELECT
          entity_sync.entity_id AS entity_id,
          entity_sync.local_seq AS record_local_seq,
          projects.local_seq AS project_local_seq,
          projects.remote_rev AS project_remote_rev,
          projects.dirty_fields AS dirty_fields
        FROM entity_sync
        JOIN projects ON projects.id = CAST(entity_sync.entity_id AS INTEGER)
        WHERE entity_sync.entity_type = ?
      ''',
        [SyncEntityType.project.name],
      );
      for (final row in projectEntityRows) {
        final entityId = row['entity_id']! as String;
        final dirtyFields =
            ((jsonDecode((row['dirty_fields'] as String?) ?? '[]')
                    as List<dynamic>))
                .map((item) => item.toString())
                .toList(growable: false);
        final projectLocalSeq = (row['project_local_seq'] as int?) ?? 0;
        final recordLocalSeq = (row['record_local_seq'] as int?) ?? 0;

        if (dirtyFields.isEmpty) {
          await txn.delete(
            'entity_sync',
            where: 'entity_type = ? AND entity_id = ?',
            whereArgs: [SyncEntityType.project.name, entityId],
          );
          continue;
        }

        if (projectLocalSeq > recordLocalSeq) {
          await txn.update(
            'entity_sync',
            {
              'local_seq': projectLocalSeq,
              'base_remote_rev': row['project_remote_rev'] as int?,
              'dirty_fields': jsonEncode(dirtyFields),
              'last_error': null,
              'leased_until': null,
              'next_attempt_at': nowIso,
              'updated_at': nowIso,
            },
            where: 'entity_type = ? AND entity_id = ?',
            whereArgs: [SyncEntityType.project.name, entityId],
          );
        }
      }

      await txn.rawUpdate(
        '''
        UPDATE photo_assets
        SET last_sync_error_code = NULL
        WHERE last_sync_error_code IS NOT NULL
          AND id NOT IN (SELECT asset_id FROM blob_upload)
          AND id NOT IN (
            SELECT entity_id FROM entity_sync WHERE entity_type = ?
          )
      ''',
        [SyncEntityType.asset.name],
      );
    });
  }

  Future<void> recoverInterruptedSyncJobs() async {
    await _db.update(
      'blob_upload',
      {
        'state': BlobUploadState.queued.name,
        'last_error':
            '[interrupted_upload] Previous upload was interrupted and will be retried.',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'state = ?',
      whereArgs: [BlobUploadState.uploading.name],
    );
  }

  Future<Map<String, SyncJobState>> getAssetSyncJobStates(
    Iterable<String> assetIds,
  ) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return const {};
    }

    final placeholders = List.filled(uniqueIds.length, '?').join(', ');
    final blobRows = await _db.query(
      'blob_upload',
      columns: ['asset_id', 'state'],
      where: 'asset_id IN ($placeholders)',
      whereArgs: uniqueIds.toList(growable: false),
      orderBy: 'updated_at DESC',
    );
    final entityRows = await _db.query(
      'entity_sync',
      columns: ['entity_id', 'last_error'],
      where: 'entity_type = ? AND entity_id IN ($placeholders)',
      whereArgs: [SyncEntityType.asset.name, ...uniqueIds],
      orderBy: 'updated_at DESC',
    );

    final states = <String, SyncJobState>{};
    for (final row in blobRows) {
      final assetId = row['asset_id']! as String;
      final state = switch (BlobUploadState.values.byName(
        row['state']! as String,
      )) {
        BlobUploadState.uploading => SyncJobState.uploading,
        BlobUploadState.failed => SyncJobState.failed,
        BlobUploadState.queued => SyncJobState.queued,
      };
      states[assetId] = _preferSyncState(states[assetId], state);
    }
    for (final row in entityRows) {
      final assetId = row['entity_id']! as String;
      final state = ((row['last_error'] as String?)?.trim().isNotEmpty ?? false)
          ? SyncJobState.failed
          : SyncJobState.queued;
      states[assetId] = _preferSyncState(states[assetId], state);
    }
    return states;
  }

  Future<Map<String, AssetOutboxState>> getAssetOutboxStates(
    Iterable<String> assetIds,
  ) async {
    final normalized = assetIds
        .map((assetId) => assetId.trim())
        .where((assetId) => assetId.isNotEmpty)
        .toSet();
    if (normalized.isEmpty) {
      return const {};
    }

    final placeholders = List.filled(normalized.length, '?').join(',');
    final blobRows = await _db.rawQuery(
      '''
      SELECT asset_id, state
      FROM blob_upload
      WHERE asset_id IN ($placeholders)
      ''',
      normalized.toList(growable: false),
    );
    final entityRows = await _db.rawQuery(
      '''
      SELECT entity_id, last_error
      FROM entity_sync
      WHERE entity_type = ?
        AND entity_id IN ($placeholders)
      ''',
      [
        SyncEntityType.asset.name,
        ...normalized,
      ],
    );

    final states = <String, AssetOutboxState>{};
    for (final row in blobRows) {
      final assetId = (row['asset_id'] as String?)?.trim();
      if (assetId == null || assetId.isEmpty) {
        continue;
      }
      final rawState = (row['state'] as String?)?.trim();
      if (rawState == null || rawState.isEmpty) {
        continue;
      }
      final next = switch (rawState) {
        'uploading' => AssetOutboxState.uploading,
        'failed' => AssetOutboxState.failed,
        _ => AssetOutboxState.queued,
      };
      states[assetId] = _preferAssetOutboxState(states[assetId], next);
    }
    for (final row in entityRows) {
      final assetId = (row['entity_id'] as String?)?.trim();
      if (assetId == null || assetId.isEmpty) {
        continue;
      }
      final lastError = (row['last_error'] as String?)?.trim();
      final next = (lastError != null && lastError.isNotEmpty)
          ? AssetOutboxState.failed
          : AssetOutboxState.queued;
      states[assetId] = _preferAssetOutboxState(states[assetId], next);
    }
    return states;
  }

  SyncJobState _preferSyncState(SyncJobState? current, SyncJobState next) {
    if (current == null) {
      return next;
    }
    const rank = <SyncJobState, int>{
      SyncJobState.failed: 3,
      SyncJobState.uploading: 2,
      SyncJobState.queued: 1,
      SyncJobState.done: 0,
      SyncJobState.paused: 0,
    };
    return (rank[next] ?? 0) >= (rank[current] ?? 0) ? next : current;
  }

  AssetOutboxState _preferAssetOutboxState(
    AssetOutboxState? current,
    AssetOutboxState next,
  ) {
    if (current == null) {
      return next;
    }
    const rank = <AssetOutboxState, int>{
      AssetOutboxState.failed: 3,
      AssetOutboxState.uploading: 2,
      AssetOutboxState.queued: 1,
    };
    return (rank[next] ?? 0) >= (rank[current] ?? 0) ? next : current;
  }

  int _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('$value') ?? 0;
  }

  Future<PhotoAsset?> getAssetById(String assetId) async {
    final rows = await _db.query(
      'photo_assets',
      where: 'id = ?',
      whereArgs: [assetId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return PhotoAsset.fromMap(rows.first);
  }

  Future<List<PhotoAsset>> getAssetsByIds(Iterable<String> assetIds) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return const [];
    }

    final placeholders = List.filled(uniqueIds.length, '?').join(', ');
    final rows = await _db.query(
      'photo_assets',
      where: 'id IN ($placeholders)',
      whereArgs: uniqueIds.toList(growable: false),
    );
    return rows.map(PhotoAsset.fromMap).toList(growable: false);
  }

  Future<PhotoAsset?> getAssetByRemoteId(String remoteAssetId) async {
    final rows = await _db.query(
      'photo_assets',
      where: 'remote_asset_id = ?',
      whereArgs: [remoteAssetId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return PhotoAsset.fromMap(rows.first);
  }

  Future<PhotoAsset?> getAssetByHash(
    String hash, {
    String? excludingAssetId,
  }) async {
    final whereParts = <String>['hash = ?'];
    final whereArgs = <Object?>[hash];
    if (excludingAssetId != null) {
      whereParts.add('id != ?');
      whereArgs.add(excludingAssetId);
    }
    final rows = await _db.query(
      'photo_assets',
      where: whereParts.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return PhotoAsset.fromMap(rows.first);
  }

  Future<void> updateAssetCloudMetadata({
    required String assetId,
    String? remoteAssetId,
    String? remoteProvider,
    String? remoteFileId,
    String? uploadSessionId,
    String? uploadPath,
    String? cloudState,
    String? lastSyncErrorCode,
    int? remoteRev,
    DateTime? deletedAt,
    List<String>? dirtyFields,
    bool clearDeletedAt = false,
  }) async {
    final values = <String, Object?>{'last_sync_error_code': lastSyncErrorCode};
    if (remoteAssetId != null) {
      values['remote_asset_id'] = remoteAssetId;
    }
    if (remoteProvider != null) {
      values['remote_provider'] = remoteProvider;
    }
    if (remoteFileId != null) {
      values['remote_file_id'] = remoteFileId;
    }
    if (uploadSessionId != null) {
      values['upload_session_id'] = uploadSessionId;
    }
    if (uploadPath != null) {
      values['upload_path'] = uploadPath;
    }
    if (cloudState != null) {
      values['cloud_state'] = cloudState;
    }
    if (remoteRev != null) {
      values['remote_rev'] = remoteRev;
    }
    if (deletedAt != null || clearDeletedAt) {
      values['deleted_at'] = deletedAt?.toIso8601String();
    }
    if (dirtyFields != null) {
      values['dirty_fields'] = jsonEncode(dirtyFields);
    }

    await _db.update(
      'photo_assets',
      values,
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> updateAssetLocalMedia({
    required String assetId,
    required String localPath,
    required String thumbPath,
    required String hash,
    String? cloudState,
    bool? existsInPhoneStorage,
  }) async {
    final values = <String, Object?>{
      'local_path': localPath,
      'thumb_path': thumbPath,
      'hash': hash,
      'cloud_state': cloudState,
      'ingest_state': AssetIngestState.ready.name,
      'last_sync_error_code': null,
    };
    if (existsInPhoneStorage != null) {
      values['exists_in_phone_storage'] = existsInPhoneStorage ? 1 : 0;
    }
    await _db.update(
      'photo_assets',
      values,
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> finalizePendingAssetIngest({
    required String assetId,
    required String localPath,
    required String thumbPath,
    required String hash,
    required bool existsInPhoneStorage,
    String? cloudState,
  }) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'photo_assets',
        columns: ['upload_generation'],
        where: 'id = ?',
        whereArgs: [assetId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final uploadGeneration = (rows.first['upload_generation'] as int?) ?? 1;
      await txn.update(
        'photo_assets',
        {
          'local_path': localPath,
          'thumb_path': thumbPath,
          'hash': hash,
          'cloud_state': cloudState,
          'exists_in_phone_storage': existsInPhoneStorage ? 1 : 0,
          'ingest_state': AssetIngestState.ready.name,
          'last_sync_error_code': null,
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
      await _upsertBlobUploadExecutor(
        txn,
        assetId: assetId,
        uploadGeneration: uploadGeneration,
        localUri: localPath,
      );
    });
  }

  Future<void> markAssetIngestFailed(
    String assetId, {
    String? errorCode,
  }) async {
    await _db.update(
      'photo_assets',
      {
        'ingest_state': AssetIngestState.failed.name,
        'last_sync_error_code': errorCode,
      },
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> purgeAsset(String assetId) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'blob_upload',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      await txn.delete(
        'asset_provider_mirrors',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      await txn.delete(
        'entity_sync',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [SyncEntityType.asset.name, assetId],
      );
      await txn.delete('photo_assets', where: 'id = ?', whereArgs: [assetId]);
    });
  }

  Future<void> purgeAssetsByIds(Iterable<String> assetIds) async {
    final ids = assetIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    await _db.transaction((txn) async {
      final placeholders = List.filled(ids.length, '?').join(', ');
      await txn.delete(
        'blob_upload',
        where: 'asset_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'asset_provider_mirrors',
        where: 'asset_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'entity_sync',
        where: 'entity_type = ? AND entity_id IN ($placeholders)',
        whereArgs: [SyncEntityType.asset.name, ...ids],
      );
      await txn.delete(
        'photo_assets',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });
  }

  Future<void> updateAssetSyncError(String assetId, String? errorCode) async {
    await _db.update(
      'photo_assets',
      {'last_sync_error_code': errorCode},
      where: 'id = ?',
      whereArgs: [assetId],
    );
  }

  Future<void> updateProviderAccountStatus(
    CloudProviderType provider, {
    required ProviderConnectionStatus connectionStatus,
    String? connectionId,
    DateTime? connectedAt,
    String? displayName,
    String? accountIdentifier,
    String? rootDisplayName,
    String? rootFolderPath,
    String? lastError,
    bool isActive = false,
    String syncHealth = 'healthy',
    int openConflictCount = 0,
  }) async {
    final tokenState = switch (connectionStatus) {
      ProviderConnectionStatus.ready => ProviderTokenState.connected,
      ProviderConnectionStatus.reconnectRequired => ProviderTokenState.expired,
      _ => ProviderTokenState.disconnected,
    };
    await _db.update(
      'provider_accounts',
      {
        'display_name': (displayName?.trim().isNotEmpty ?? false)
            ? displayName!.trim()
            : provider.label,
        'connection_id': (connectionId?.trim().isNotEmpty ?? false)
            ? connectionId!.trim()
            : null,
        'account_identifier': (accountIdentifier?.trim().isNotEmpty ?? false)
            ? accountIdentifier!.trim()
            : null,
        'connection_status': connectionStatus.storageValue,
        'token_state': tokenState.name,
        'connected_at': connectedAt?.toIso8601String(),
        'root_display_name': (rootDisplayName?.trim().isNotEmpty ?? false)
            ? rootDisplayName!.trim()
            : null,
        'root_folder_path': (rootFolderPath?.trim().isNotEmpty ?? false)
            ? rootFolderPath!.trim()
            : null,
        'last_error': (lastError?.trim().isNotEmpty ?? false)
            ? lastError!.trim()
            : null,
        'is_active': isActive ? 1 : 0,
        'sync_health': syncHealth.trim().isNotEmpty
            ? syncHealth.trim()
            : 'healthy',
        'open_conflict_count': openConflictCount < 0 ? 0 : openConflictCount,
      },
      where: 'provider_type = ?',
      whereArgs: [provider.key],
    );
  }

  Future<void> upsertProjectProviderMirror({
    required int localProjectId,
    required String providerConnectionId,
    required String status,
    String? providerFolderId,
    String? providerRev,
    String? lastError,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _db.insert('project_provider_mirrors', {
      'local_project_id': localProjectId,
      'provider_connection_id': providerConnectionId,
      'status': status,
      'provider_folder_id': providerFolderId,
      'provider_rev': providerRev,
      'last_error': lastError,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertAssetProviderMirror({
    required String assetId,
    required String providerConnectionId,
    required String status,
    String? providerFileId,
    String? remotePath,
    String? providerRev,
    String? lastError,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _db.insert('asset_provider_mirrors', {
      'asset_id': assetId,
      'provider_connection_id': providerConnectionId,
      'status': status,
      'provider_file_id': providerFileId,
      'remote_path': remotePath,
      'provider_rev': providerRev,
      'last_error': lastError,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getAssetProviderMirrorStatuses({
    required Iterable<String> assetIds,
    required String providerConnectionId,
  }) async {
    final ids = assetIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) {
      return const <String, String>{};
    }
    final rows = await _db.query(
      'asset_provider_mirrors',
      columns: ['asset_id', 'status'],
      where:
          'provider_connection_id = ? AND asset_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [providerConnectionId, ...ids],
    );
    return {
      for (final row in rows)
        row['asset_id']! as String: row['status']! as String,
    };
  }

  Future<Map<String, int>> getProjectProviderMirrorCounts(
    String providerConnectionId,
  ) async {
    final rows = await _db.rawQuery(
      '''
      SELECT status, COUNT(*) AS count
      FROM project_provider_mirrors
      WHERE provider_connection_id = ?
      GROUP BY status
      ''',
      [providerConnectionId],
    );
    return {
      for (final row in rows)
        (row['status']! as String): ((row['count'] as int?) ?? 0),
    };
  }

  Future<Map<String, int>> getAssetProviderMirrorCounts(
    String providerConnectionId,
  ) async {
    final rows = await _db.rawQuery(
      '''
      SELECT status, COUNT(*) AS count
      FROM asset_provider_mirrors
      WHERE provider_connection_id = ?
      GROUP BY status
      ''',
      [providerConnectionId],
    );
    return {
      for (final row in rows)
        (row['status']! as String): ((row['count'] as int?) ?? 0),
    };
  }

  Future<bool> assetExistsByHash(String hash) async {
    final rows = await _db.query(
      'photo_assets',
      columns: ['id'],
      where: 'hash = ? AND status = ?',
      whereArgs: [hash, AssetStatus.active.name],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _upsertEntitySyncExecutor(
    DatabaseExecutor executor, {
    required SyncEntityType entityType,
    required String entityId,
    required List<String> dirtyFields,
    required int localSeq,
    required int? baseRemoteRev,
  }) async {
    final now = DateTime.now();
    await executor.insert(
      'entity_sync',
      EntitySyncRecord(
        entityType: entityType,
        entityId: entityId,
        nextAttemptAt: now,
        attempts: 0,
        leasedUntil: null,
        lastError: null,
        dirtyFields: dirtyFields,
        baseRemoteRev: baseRemoteRev,
        localSeq: localSeq,
        createdAt: now,
        updatedAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _upsertBlobUploadExecutor(
    DatabaseExecutor executor, {
    required String assetId,
    required int uploadGeneration,
    required String localUri,
  }) async {
    final now = DateTime.now();
    await executor.insert(
      'blob_upload',
      BlobUploadTask(
        assetId: assetId,
        uploadGeneration: uploadGeneration,
        localUri: localUri,
        state: BlobUploadState.queued,
        bytesSent: 0,
        attempts: 0,
        leasedUntil: null,
        lastError: null,
        createdAt: now,
        updatedAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<int, int>> getProjectCounts() async {
    final rows = await _db.rawQuery(
      '''
      SELECT project_id, COUNT(*) AS cnt
      FROM photo_assets
      WHERE status = ?
      GROUP BY project_id
    ''',
      [AssetStatus.active.name],
    );

    final map = <int, int>{};
    for (final row in rows) {
      map[row['project_id']! as int] = row['cnt']! as int;
    }
    return map;
  }

  Future<List<SyncJob>> _buildSyntheticSyncJobs({Set<String>? assetIds}) async {
    final assets = await getAssetsByIds(
      assetIds ??
          (await _db.query(
            'photo_assets',
            columns: ['id'],
            where: 'status != ?',
            whereArgs: [AssetStatus.deleted.name],
          )).map((row) => row['id']! as String),
    );
    if (assets.isEmpty) {
      return const [];
    }

    final assetById = {for (final asset in assets) asset.id: asset};
    final ids = assetById.keys.toList(growable: false);
    final placeholders = List.filled(ids.length, '?').join(', ');
    final blobRows = await _db.query(
      'blob_upload',
      where: 'asset_id IN ($placeholders)',
      whereArgs: ids,
      orderBy: 'updated_at DESC',
    );
    final entityRows = await _db.query(
      'entity_sync',
      where: 'entity_type = ? AND entity_id IN ($placeholders)',
      whereArgs: [SyncEntityType.asset.name, ...ids],
      orderBy: 'updated_at DESC',
    );

    final jobs = <SyncJob>[];
    final seen = <String>{};
    for (final row in blobRows) {
      final task = BlobUploadTask.fromMap(row);
      final asset = assetById[task.assetId];
      if (asset == null || seen.contains(asset.id)) {
        continue;
      }
      seen.add(asset.id);
      jobs.add(
        SyncJob(
          id: 'blob:${asset.id}:${task.uploadGeneration}',
          assetId: asset.id,
          providerType: CloudProviderType.backend,
          projectId: asset.projectId,
          attemptCount: task.attempts,
          state: switch (task.state) {
            BlobUploadState.queued => SyncJobState.queued,
            BlobUploadState.uploading => SyncJobState.uploading,
            BlobUploadState.failed => SyncJobState.failed,
          },
          lastError: task.lastError,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
        ),
      );
    }
    for (final row in entityRows) {
      final record = EntitySyncRecord.fromMap(row);
      final asset = assetById[record.entityId];
      if (asset == null || seen.contains(asset.id)) {
        continue;
      }
      seen.add(asset.id);
      jobs.add(
        SyncJob(
          id: 'entity:${record.entityType.name}:${record.entityId}',
          assetId: asset.id,
          providerType: CloudProviderType.backend,
          projectId: asset.projectId,
          attemptCount: record.attempts,
          state: record.hasError ? SyncJobState.failed : SyncJobState.queued,
          lastError: record.lastError,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
        ),
      );
    }
    jobs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return jobs;
  }
}

enum AssetIntegrityIssueKind {
  duplicateRemoteAssetId,
  duplicateRemoteHash,
  inconsistentDeletedState,
}

class AssetIntegrityIssue {
  const AssetIntegrityIssue({
    required this.kind,
    required this.value,
    required this.count,
  });

  final AssetIntegrityIssueKind kind;
  final String value;
  final int count;
}

String rebaseMediaPath(String originalPath, String currentMediaRootPath) {
  final trimmedPath = originalPath.trim();
  if (trimmedPath.isEmpty) {
    return originalPath;
  }

  final normalizedOriginal = trimmedPath.replaceAll('\\', '/');
  const marker = '/joblens_media/';
  final markerIndex = normalizedOriginal.indexOf(marker);
  if (markerIndex == -1) {
    return originalPath;
  }

  final suffix = normalizedOriginal.substring(markerIndex + marker.length);
  if (suffix.trim().isEmpty) {
    return originalPath;
  }

  return p.joinAll([
    currentMediaRootPath,
    ...suffix.split('/').where((segment) => segment.isNotEmpty),
  ]);
}
