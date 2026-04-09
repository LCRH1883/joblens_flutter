import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_provider.dart';
import '../models/app_theme_mode.dart';
import '../models/blob_upload_task.dart';
import '../models/entity_sync_record.dart';
import '../models/library_import_mode.dart';
import '../models/photo_asset.dart';
import '../models/project.dart';
import '../models/provider_account.dart';
import '../models/sync_log_entry.dart';
import '../models/sync_job.dart';

class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;
  static const _uuid = Uuid();
  static const _schemaVersion = 9;

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
          await _resetSchema(db);
          await _createSchema(db);
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

  static Future<void> _resetSchema(Database db) async {
    await db.execute('DROP TABLE IF EXISTS entity_sync');
    await db.execute('DROP TABLE IF EXISTS blob_upload');
    await db.execute('DROP TABLE IF EXISTS sync_state');
    await db.execute('DROP TABLE IF EXISTS sync_jobs');
    await db.execute('DROP TABLE IF EXISTS sync_log_entries');
    await db.execute('DROP TABLE IF EXISTS provider_accounts');
    await db.execute('DROP TABLE IF EXISTS photo_assets');
    await db.execute('DROP TABLE IF EXISTS projects');
    await db.execute('DROP TABLE IF EXISTS app_state');
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
        token_state TEXT NOT NULL,
        connected_at TEXT
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

  Future<void> clearUserScopedData() async {
    await _db.transaction((txn) async {
      await txn.delete('entity_sync');
      await txn.delete('blob_upload');
      await txn.delete('sync_state');
      await txn.delete('sync_log_entries');
      await txn.delete('photo_assets');
      await txn.delete('projects');
      await txn.delete('provider_accounts');
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
        baseRemoteRev: current.isEmpty ? null : current.first['remote_rev'] as int?,
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
        baseRemoteRev: projectRows.isEmpty ? null : projectRows.first['remote_rev'] as int?,
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
      uploadGeneration: asset.uploadGeneration <= 0 ? 1 : asset.uploadGeneration,
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
      'cloud_state': deleted
          ? AssetCloudState.deleted
          : AssetCloudState.cloudOnly,
      'exists_in_phone_storage': 0,
      'deleted_at': deleted ? createdAt.toIso8601String() : null,
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
        deleted: deleted,
      );
      await _db.update(
        'photo_assets',
        {'remote_rev': remoteRev, 'dirty_fields': '[]'},
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
        'cloud_state': deleted
            ? AssetCloudState.deleted
            : existing.localPath.isEmpty
            ? AssetCloudState.cloudOnly
            : AssetCloudState.localAndCloud,
        'status': deleted ? AssetStatus.deleted.name : AssetStatus.active.name,
        'deleted_at': deleted ? DateTime.now().toIso8601String() : null,
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
        baseRemoteRev: current.isEmpty ? null : current.first['remote_rev'] as int?,
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
    for (final provider in CloudProviderTypeX.userConfigurableProviders) {
      await _db.insert('provider_accounts', {
        'id': _uuid.v4(),
        'provider_type': provider.key,
        'display_name': provider.label,
        'token_state': ProviderTokenState.disconnected.name,
        'connected_at': null,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await _db.update(
        'provider_accounts',
        {'display_name': provider.label, 'connected_at': null},
        where: 'provider_type = ? AND token_state = ?',
        whereArgs: [provider.key, ProviderTokenState.disconnected.name],
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

  Future<void> setProviderConnection(
    CloudProviderType provider,
    ProviderTokenState state,
  ) async {
    await _db.update(
      'provider_accounts',
      {
        'token_state': state.name,
        'connected_at': state == ProviderTokenState.connected
            ? DateTime.now().toIso8601String()
            : null,
      },
      where: 'provider_type = ?',
      whereArgs: [provider.key],
    );
  }

  Future<List<CloudProviderType>> getConnectedProviders() async {
    final rows = await _db.query(
      'provider_accounts',
      columns: ['provider_type'],
      where: 'token_state = ?',
      whereArgs: [ProviderTokenState.connected.name],
    );
    return rows
        .map(
          (row) => CloudProviderTypeX.fromKey(row['provider_type']! as String),
        )
        .toList();
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
    if (asset.projectId != projectId) {
      await _db.update(
        'photo_assets',
        {
          'project_id': projectId,
          'local_seq': _nextLocalSeq(),
          'dirty_fields': '["project_id"]',
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
    }
    await upsertEntitySync(
      entityType: SyncEntityType.asset,
      entityId: assetId,
      dirtyFields: const ['project_id'],
      baseRemoteRev: asset.remoteRev,
      localSeq: asset.localSeq == 0 ? _nextLocalSeq() : asset.localSeq,
    );
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
    return jobs.cast<SyncJob?>().firstWhere((job) => job?.assetId == assetId, orElse: () => null);
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

  Future<String> getOrCreateClientDeviceId() async {
    final existing = await getSyncStateValue('client_device_id');
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }
    final generated = _uuid.v4();
    await setSyncStateValue('client_device_id', generated);
    return generated;
  }

  Future<String?> getBackendDeviceId() => getSyncStateValue('backend_device_id');

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

  Future<List<BlobUploadTask>> getPendingBlobUploadTasks({
    int limit = 25,
  }) async {
    final now = DateTime.now().toIso8601String();
    final rows = await _db.query(
      'blob_upload',
      where:
          '(leased_until IS NULL OR leased_until <= ?) AND state IN (?, ?)',
      whereArgs: [now, BlobUploadState.queued.name, BlobUploadState.failed.name],
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

  Future<List<SyncJob>> getPendingSyncJobs() async {
    final jobs = await _buildSyntheticSyncJobs();
    return jobs
        .where(
          (job) =>
              job.state == SyncJobState.queued ||
              job.state == SyncJobState.failed ||
              job.state == SyncJobState.paused,
        )
        .take(25)
        .toList(growable: false);
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
    await _db.update(
      'entity_sync',
      {
        'last_error': null,
        'next_attempt_at': DateTime.now().toIso8601String(),
        'leased_until': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'last_error IS NOT NULL',
    );
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

  Future<PhotoAsset?> getAssetByHash(String hash, {String? excludingAssetId}) async {
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
  }) async {
    await _db.update(
      'photo_assets',
      {
        'local_path': localPath,
        'thumb_path': thumbPath,
        'hash': hash,
        'cloud_state': cloudState,
        'ingest_state': AssetIngestState.ready.name,
      },
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

  Future<void> markAssetIngestFailed(String assetId, {String? errorCode}) async {
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
      await txn.delete('blob_upload', where: 'asset_id = ?', whereArgs: [assetId]);
      await txn.delete(
        'entity_sync',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [SyncEntityType.asset.name, assetId],
      );
      await txn.delete('photo_assets', where: 'id = ?', whereArgs: [assetId]);
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
    CloudProviderType provider,
    ProviderTokenState state, {
    DateTime? connectedAt,
  }) async {
    await _db.update(
      'provider_accounts',
      {
        'token_state': state.name,
        'connected_at': connectedAt?.toIso8601String(),
      },
      where: 'provider_type = ?',
      whereArgs: [provider.key],
    );
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
          ))
              .map((row) => row['id']! as String),
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
