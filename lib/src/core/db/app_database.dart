import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_provider.dart';
import '../models/app_theme_mode.dart';
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
  static const _schemaVersion = 8;

  static Future<AppDatabase> open({String? databasePath}) async {
    final resolvedPath = databasePath ?? await _defaultDatabasePath();

    final db = await openDatabase(
      resolvedPath,
      version: _schemaVersion,
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
            exists_in_phone_storage INTEGER NOT NULL DEFAULT 0,
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
        await db.execute('CREATE INDEX idx_sync_state ON sync_jobs(state)');
        await db.execute(
          'CREATE UNIQUE INDEX uq_sync_asset_provider ON sync_jobs(asset_id, provider_type)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE projects ADD COLUMN notes TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE projects ADD COLUMN remote_project_id TEXT",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN remote_asset_id TEXT",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN upload_session_id TEXT",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN upload_path TEXT",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN cloud_state TEXT NOT NULL DEFAULT 'local_and_cloud'",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN last_sync_error_code TEXT",
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_assets_remote_asset_id ON photo_assets(remote_asset_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_projects_remote_project_id ON projects(remote_project_id)',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN remote_provider TEXT",
          );
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN remote_file_id TEXT",
          );
        }
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS app_state (
              key TEXT PRIMARY KEY,
              value TEXT
            )
          ''');
        }
        if (oldVersion < 6) {
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
        }
        if (oldVersion < 7) {
          await db.execute("ALTER TABLE projects ADD COLUMN start_date TEXT");
        }
        if (oldVersion < 8) {
          await db.execute(
            "ALTER TABLE photo_assets ADD COLUMN exists_in_phone_storage INTEGER NOT NULL DEFAULT 0",
          );
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
      await txn.delete('sync_jobs');
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
    });
  }

  Future<List<Project>> getProjects() async {
    final rows = await _db.query('projects', orderBy: 'created_at ASC, id ASC');
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

  Future<int> createProject(String name, {DateTime? startDate}) async {
    final now = DateTime.now().toIso8601String();
    return _db.insert('projects', {
      'name': name,
      'notes': '',
      'start_date': startDate?.toIso8601String(),
      'remote_project_id': null,
      'cover_asset_id': null,
      'created_at': now,
      'updated_at': now,
      'sync_folder_map': '{}',
    }, conflictAlgorithm: ConflictAlgorithm.abort);
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
    await _db.update(
      'projects',
      {
        'name': name,
        'start_date': startDate?.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [projectId],
    );
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
      await txn.update(
        'photo_assets',
        {'project_id': fallbackProjectId},
        where: 'project_id = ?',
        whereArgs: [projectId],
      );
      await txn.delete('projects', where: 'id = ?', whereArgs: [projectId]);
    });
  }

  Future<void> upsertAsset(PhotoAsset asset) async {
    await _db.insert(
      'photo_assets',
      asset.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _db.update(
      'projects',
      {
        'cover_asset_id': asset.id,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [asset.projectId],
    );
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
      'last_sync_error_code': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    await _db.transaction((txn) async {
      await txn.update(
        'photo_assets',
        {'project_id': projectId},
        where: 'id = ?',
        whereArgs: [assetId],
      );
      await txn.update(
        'projects',
        {'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [projectId],
      );
    });
  }

  Future<void> softDeleteAsset(String assetId) async {
    await _db.update(
      'photo_assets',
      {'status': AssetStatus.deleted.name},
      where: 'id = ?',
      whereArgs: [assetId],
    );
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
    final now = DateTime.now();
    final updated = await _db.update(
      'sync_jobs',
      {
        'project_id': projectId,
        'attempt_count': 0,
        'state': SyncJobState.queued.name,
        'last_error': null,
        'updated_at': now.toIso8601String(),
      },
      where: 'asset_id = ? AND provider_type = ?',
      whereArgs: [assetId, provider.key],
    );
    if (updated > 0) {
      return;
    }

    await _db.insert(
      'sync_jobs',
      SyncJob(
        id: _uuid.v4(),
        assetId: assetId,
        providerType: provider,
        projectId: projectId,
        attemptCount: 0,
        state: SyncJobState.queued,
        lastError: null,
        createdAt: now,
        updatedAt: now,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<SyncJob>> getSyncJobs() async {
    final rows = await _db.query('sync_jobs', orderBy: 'updated_at DESC');
    return rows.map(SyncJob.fromMap).toList();
  }

  Future<SyncJob?> getSyncJobForAsset({
    required String assetId,
    required CloudProviderType provider,
  }) async {
    final rows = await _db.query(
      'sync_jobs',
      where: 'asset_id = ? AND provider_type = ?',
      whereArgs: [assetId, provider.key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return SyncJob.fromMap(rows.first);
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

  Future<List<SyncJob>> getPendingSyncJobs() async {
    final rows = await _db.query(
      'sync_jobs',
      where: 'state IN (?, ?, ?)',
      whereArgs: [
        SyncJobState.queued.name,
        SyncJobState.failed.name,
        SyncJobState.paused.name,
      ],
      orderBy: 'created_at ASC',
      limit: 25,
    );
    return rows.map(SyncJob.fromMap).toList();
  }

  Future<bool> updateSyncJob(SyncJob job) async {
    final updated = await _db.update(
      'sync_jobs',
      {
        'attempt_count': job.attemptCount,
        'state': job.state.name,
        'last_error': job.lastError,
        'updated_at': DateTime.now().toIso8601String(),
      },
      // Avoid letting stale in-flight sync snapshots overwrite a newer
      // queued job that changed project/state while the queue was running.
      where: 'id = ? AND updated_at = ?',
      whereArgs: [job.id, job.updatedAt.toIso8601String()],
    );
    return updated > 0;
  }

  Future<void> setAllFailedToQueued() async {
    await _db.update(
      'sync_jobs',
      {
        'state': SyncJobState.queued.name,
        'last_error': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'state = ?',
      whereArgs: [SyncJobState.failed.name],
    );
  }

  Future<void> recoverInterruptedSyncJobs() async {
    await _db.update(
      'sync_jobs',
      {
        'state': SyncJobState.queued.name,
        'last_error':
            '[interrupted_upload] Previous upload was interrupted and will be retried.',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'state = ?',
      whereArgs: [SyncJobState.uploading.name],
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

  Future<PhotoAsset?> getAssetByHash(String hash) async {
    final rows = await _db.query(
      'photo_assets',
      where: 'hash = ?',
      whereArgs: [hash],
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
      },
      where: 'id = ?',
      whereArgs: [assetId],
    );
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
