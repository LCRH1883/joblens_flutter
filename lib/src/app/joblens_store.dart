import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import '../core/db/app_database.dart';
import '../core/api/api_exception.dart';
import '../core/models/app_theme_mode.dart';
import '../core/models/cloud_provider.dart';
import '../core/models/library_import_mode.dart';
import '../core/models/photo_asset.dart';
import '../core/models/project.dart';
import '../core/models/provider_account.dart';
import '../core/models/sync_log_entry.dart';
import '../core/models/sync_job.dart';
import '../core/storage/media_storage_service.dart';
import '../core/sync/sync_service.dart';

const int kProjectNotesMaxLength = 4000;

final joblensStoreProvider = Provider<JoblensStore>(
  (ref) => throw UnimplementedError(
    'joblensStoreProvider must be overridden in main.dart',
  ),
);

final joblensStoreListenableProvider = ChangeNotifierProvider<JoblensStore>(
  (ref) => ref.watch(joblensStoreProvider),
);

class JoblensStore extends ChangeNotifier {
  JoblensStore({
    required AppDatabase database,
    required MediaStorageService mediaStorage,
    required SyncService syncService,
    ImagePicker? imagePicker,
    String? Function()? currentAuthUserIdProvider,
    Future<void> Function()? signOutAction,
  }) : _database = database,
       _mediaStorage = mediaStorage,
       _syncService = syncService,
       _picker = imagePicker ?? ImagePicker(),
       _currentAuthUserIdProvider = currentAuthUserIdProvider,
       _signOutAction = signOutAction;

  final AppDatabase _database;
  final MediaStorageService _mediaStorage;
  final SyncService _syncService;
  final ImagePicker _picker;
  final String? Function()? _currentAuthUserIdProvider;
  final Future<void> Function()? _signOutAction;

  bool _isLoading = true;
  bool _isBusy = false;
  bool _isDisposed = false;
  String? _lastError;
  int _reauthenticationRequestCount = 0;
  Future<void> _pendingBackgroundSync = Future.value();
  ProjectSortMode _projectSortMode = ProjectSortMode.name;
  AppThemeMode _appThemeMode = AppThemeMode.system;
  LibraryImportMode _libraryImportMode = LibraryImportMode.copy;

  List<PhotoAsset> _assets = const [];
  List<Project> _projects = const [];
  Map<int, int> _projectCounts = const {};
  List<ProviderAccount> _providers = const [];
  List<SyncJob> _syncJobs = const [];
  List<SyncLogEntry> _syncLogs = const [];

  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get lastError => _lastError;
  int get reauthenticationRequestCount => _reauthenticationRequestCount;
  List<PhotoAsset> get assets => _assets;
  List<Project> get projects => _sortProjects(_projects, _projectSortMode);
  Map<int, int> get projectCounts => _projectCounts;
  List<ProviderAccount> get providers => _providers;
  List<SyncJob> get syncJobs => _syncJobs;
  List<SyncLogEntry> get syncLogs => _syncLogs;
  ProjectSortMode get projectSortMode => _projectSortMode;
  AppThemeMode get appThemeMode => _appThemeMode;
  LibraryImportMode get libraryImportMode => _libraryImportMode;

  Future<void> initialize() async {
    await _synchronizeAuthUser(_currentAuthUserIdProvider?.call());
    _isLoading = false;
    _notifyListenersIfActive();
  }

  Future<void> syncAuthSession(Session? session) async {
    if (session?.user.id != null) {
      _lastError = null;
    }
    await _synchronizeAuthUser(session?.user.id);
  }

  Future<void> signOut() async {
    await _runBusy(() async {
      final signOutAction = _signOutAction;
      if (signOutAction != null) {
        await signOutAction();
      }
    });
  }

  Future<void> deleteAccount() async {
    await _runBusy(() async {
      await _syncService.deleteAccount();
      final signOutAction = _signOutAction;
      if (signOutAction != null) {
        try {
          await signOutAction();
        } catch (error) {
          // Auth user may already be deleted server-side.
          if (kDebugMode) {
            debugPrint('Sign out after account deletion failed: $error');
          }
        }
      }
      await _synchronizeAuthUser(null);
    });
  }

  Future<void> refresh() async {
    if (_isDisposed) {
      return;
    }
    await _hydrateLocalState();
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      _lastError = null;
      _notifyListenersIfActive();
      return;
    }

    String? remoteMergeError;
    try {
      await _syncService.refreshProviderConnections();
    } catch (error, stackTrace) {
      await _handleError(error);
      remoteMergeError = _requiresReauthentication(error)
          ? _lastError
          : error.toString();
      if (kDebugMode) {
        debugPrint('Provider refresh failed: $error\n$stackTrace');
      }
    }
    await _hydrateLocalState();
    try {
      _projects = await _syncService.syncRemoteProjects(_projects);
      await _hydrateLocalState();
    } catch (error, stackTrace) {
      await _handleError(error);
      remoteMergeError = _requiresReauthentication(error)
          ? _lastError
          : error.toString();
      if (kDebugMode) {
        debugPrint('Remote project sync failed: $error\n$stackTrace');
      }
    }
    try {
      await _syncService.mergeRemoteAssets(_projects);
      await _hydrateLocalState();
    } catch (error, stackTrace) {
      await _handleError(error);
      remoteMergeError = _requiresReauthentication(error)
          ? _lastError
          : error.toString();
      if (kDebugMode) {
        debugPrint('Remote merge failed: $error\n$stackTrace');
      }
    }
    if (remoteMergeError != null) {
      _lastError = remoteMergeError;
    }
    _notifyListenersIfActive();
  }

  Future<void> ingestCapturedFile(
    File sourceFile, {
    int? projectId,
    bool processSyncNow = false,
  }) async {
    await _runBusy(() async {
      final targetProjectId = projectId ?? _defaultProjectId;
      final asset = await _mediaStorage.ingestFile(
        source: sourceFile,
        sourceType: AssetSourceType.captured,
        projectId: targetProjectId,
      );

      if (await _database.assetExistsByHash(asset.hash)) {
        return;
      }

      await _database.upsertAsset(asset);
      await _syncService.enqueueAsset(asset);
      await _hydrateLocalState();
      _notifyListenersIfActive();
      if (processSyncNow) {
        await _runBackgroundSyncRefresh();
      } else {
        unawaited(_runBackgroundSyncRefresh());
      }
    });
  }

  Future<void> importFromPhoneGallery({int? projectId}) async {
    await _runBusy(() async {
      final selectedFiles = await _picker.pickMultiImage(imageQuality: 100);
      if (selectedFiles.isEmpty) {
        return;
      }

      final targetProjectId = projectId ?? _defaultProjectId;
      for (final selected in selectedFiles) {
        final source = File(selected.path);
        if (!source.existsSync()) {
          continue;
        }

        final asset = await _mediaStorage.ingestFile(
          source: source,
          sourceType: AssetSourceType.imported,
          projectId: targetProjectId,
        );

        if (await _database.assetExistsByHash(asset.hash)) {
          continue;
        }

        await _database.upsertAsset(asset);
        await _database.setAssetExistsInPhoneStorage(asset.id, true);
        await _syncService.enqueueAsset(asset);
      }

      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(_runBackgroundSyncRefresh());
    });
  }

  Future<void> importFromPhoneLibraryAssets(
    List<AssetEntity> assets, {
    int? projectId,
    required LibraryImportMode mode,
  }) async {
    await _runBusy(() async {
      if (assets.isEmpty) {
        return;
      }

      final importedAssetIds = <String>[];
      final targetProjectId = projectId ?? _defaultProjectId;
      final tempDir = await getTemporaryDirectory();

      for (final entity in assets) {
        final source = await _resolveLibraryAssetFile(entity, tempDir);
        if (source == null || !source.existsSync()) {
          continue;
        }

        final asset = await _mediaStorage.ingestFile(
          source: source,
          sourceType: AssetSourceType.imported,
          projectId: targetProjectId,
          createdAt: entity.createDateTime,
        );

        if (await _database.assetExistsByHash(asset.hash)) {
          continue;
        }

        await _database.upsertAsset(asset);
        await _database.setAssetExistsInPhoneStorage(
          asset.id,
          mode == LibraryImportMode.copy,
        );
        await _syncService.enqueueAsset(asset);
        importedAssetIds.add(entity.id);
      }

      if (mode == LibraryImportMode.move && importedAssetIds.isNotEmpty) {
        await PhotoManager.editor.deleteWithIds(importedAssetIds);
      }

      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(_runBackgroundSyncRefresh());
    });
  }

  Future<void> createProject(String name, {DateTime? startDate}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _runBusy(() async {
      final normalizedStartDate = _normalizeProjectStartDate(startDate);
      final projectId = await _database.createProject(
        trimmed,
        startDate: normalizedStartDate,
      );
      final localProject = Project(
        id: projectId,
        name: trimmed,
        notes: '',
        startDate: normalizedStartDate,
        remoteProjectId: null,
        coverAssetId: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        syncFolderMap: const {},
      );
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(
        _queueBackgroundCloudWork(
          action: () => _syncService.syncProject(localProject),
          refresh: true,
        ),
      );
    });
  }

  Future<void> updateProjectMetadata(
    int projectId, {
    required String name,
    DateTime? startDate,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _runBusy(() async {
      final existing = (await _database.getProjects()).firstWhere(
        (item) => item.id == projectId,
      );
      final normalizedStartDate = _normalizeProjectStartDate(startDate);
      final normalizedName = existing.name == 'Inbox' ? 'Inbox' : trimmed;
      await _database.updateProjectMetadata(
        projectId,
        name: normalizedName,
        startDate: normalizedStartDate,
      );
      final project = (await _database.getProjects()).firstWhere(
        (item) => item.id == projectId,
      );
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(
        _queueBackgroundCloudWork(
          action: () => _syncService.syncProject(project),
          refresh: true,
        ),
      );
    });
  }

  Future<void> updateProjectNotes(int projectId, String notes) async {
    final normalized = _normalizeProjectNotesForSave(notes);
    if (normalized.length > kProjectNotesMaxLength) {
      _lastError =
          'Project notes must be at most $kProjectNotesMaxLength characters.';
      _notifyListenersIfActive();
      return;
    }
    await _runBusy(() async {
      await _database.updateProjectNotes(projectId, normalized);
      await _hydrateLocalState();
      _notifyListenersIfActive();
    });
  }

  Future<void> updateProjectRemoteId(
    int projectId,
    String? remoteProjectId,
  ) async {
    await _runBusy(() async {
      await _database.updateProjectRemoteId(projectId, remoteProjectId);
      await _hydrateLocalState();
      _notifyListenersIfActive();
    });
  }

  Future<void> deleteProject(int projectId) async {
    if (projectId == _defaultProjectId) {
      return;
    }

    await _runBusy(() async {
      final currentProjects = await _database.getProjects();
      final project = currentProjects.firstWhere(
        (item) => item.id == projectId,
      );
      final movedAssetIds = _assets
          .where((asset) => asset.projectId == projectId)
          .map((asset) => asset.id)
          .toSet();

      await _database.deleteProject(
        projectId,
        fallbackProjectId: _defaultProjectId,
      );
      final updatedAssets = await _database.getAssets();
      final movedAssets = updatedAssets
          .where((asset) => movedAssetIds.contains(asset.id))
          .toList(growable: false);
      await _syncService.enqueueAssets(movedAssets);
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(
        _queueBackgroundCloudWork(
          action: () async {
            if (project.remoteProjectId != null &&
                project.remoteProjectId!.isNotEmpty) {
              try {
                await _syncService.archiveProject(project.remoteProjectId!);
              } catch (error, stackTrace) {
                if (kDebugMode) {
                  debugPrint('Archive project failed: $error\n$stackTrace');
                }
              }
            }
          },
          processQueue: true,
          refresh: true,
        ),
      );
    });
  }

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    await _runBusy(() async {
      await _database.moveAssetToProject(assetId, projectId);
      final movedAsset = await _database.getAssetById(assetId);
      if (movedAsset != null) {
        await _syncService.enqueueAsset(movedAsset);
      }
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(_runBackgroundSyncRefresh());
    });
  }

  Future<void> moveAssetsToProject(
    Iterable<String> assetIds,
    int projectId,
  ) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return;
    }

    await _runBusy(() async {
      for (final assetId in uniqueIds) {
        await _database.moveAssetToProject(assetId, projectId);
      }
      final movedAssets = await _database.getAssetsByIds(uniqueIds);
      await _syncService.enqueueAssets(movedAssets);
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(_runBackgroundSyncRefresh());
    });
  }

  Future<void> softDeleteAsset(String assetId) async {
    await _runBusy(() async {
      final asset = await _database.getAssetById(assetId);
      await _database.softDeleteAsset(assetId);
      await _hydrateLocalState();
      _notifyListenersIfActive();
      if (asset != null &&
          asset.remoteAssetId != null &&
          asset.remoteAssetId!.isNotEmpty) {
        unawaited(
          _queueBackgroundCloudWork(
            action: () => _syncService.deleteRemoteAsset(asset),
            refresh: true,
          ),
        );
      }
    });
  }

  Future<void> softDeleteAssets(Iterable<String> assetIds) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return;
    }

    await _runBusy(() async {
      final assets = await _database.getAssetsByIds(uniqueIds);
      for (final assetId in uniqueIds) {
        await _database.softDeleteAsset(assetId);
      }
      await _hydrateLocalState();
      _notifyListenersIfActive();
      final remotelySyncedAssets = assets
          .where(
            (asset) =>
                asset.remoteAssetId != null && asset.remoteAssetId!.isNotEmpty,
          )
          .toList(growable: false);
      if (remotelySyncedAssets.isNotEmpty) {
        unawaited(
          _queueBackgroundCloudWork(
            action: () async {
              for (final asset in remotelySyncedAssets) {
                await _syncService.deleteRemoteAsset(asset);
              }
            },
            refresh: true,
          ),
        );
      }
    });
  }

  Future<void> disconnectProvider(CloudProviderType provider) async {
    await _runBusy(() async {
      await _syncService.disconnectProvider(provider);
      await refresh();
    });
  }

  Future<String?> beginProviderConnection(CloudProviderType provider) async {
    String? authUrl;
    await _runBusy(() async {
      authUrl = await _syncService.beginProviderConnection(provider);
    });
    return authUrl;
  }

  Future<void> backfillCloudSyncAfterProviderConnection() async {
    await _runBusy(() async {
      await _syncService.refreshProviderConnections();
      final providerAccounts = await _database.getProviderAccounts();
      final selectedProvider = providerAccounts
          .where(
            (provider) =>
                provider.tokenState != ProviderTokenState.disconnected,
          )
          .map((provider) => provider.providerType.key)
          .cast<String?>()
          .firstWhere((provider) => provider != null, orElse: () => null);

      final assetsNeedingRemoteSync = (await _database.getAssets()).where(
        (asset) =>
            asset.status == AssetStatus.active &&
            asset.localPath.trim().isNotEmpty &&
            ((asset.remoteAssetId == null || asset.remoteAssetId!.isEmpty) ||
                (selectedProvider != null &&
                    asset.remoteProvider != selectedProvider)),
      );

      await _syncService.retryFailed();
      await _syncService.enqueueAssets(assetsNeedingRemoteSync);
      _projects = await _database.getProjects();
      await _syncService.processQueue(_projects);
      await refresh();
    });
  }

  Future<void> connectNextcloud({
    required String serverUrl,
    required String username,
    required String appPassword,
  }) async {
    await _runBusy(() async {
      await _syncService.connectNextcloud(
        serverUrl: serverUrl,
        username: username,
        appPassword: appPassword,
      );
      await refresh();
    });
  }

  Future<void> runSyncNow() async {
    await _runBusy(() async {
      _projects = await _database.getProjects();
      await _syncService.processQueue(_projects);
      await refresh();
    });
  }

  Future<void> retryFailedSyncJobs() async {
    await _runBusy(() async {
      await _syncService.retryFailed();
      await _syncService.processQueue(_projects);
      await refresh();
    });
  }

  Future<File> exportSyncLog() async {
    final logs = await _database.getAllSyncLogs();
    final buffer = StringBuffer();
    buffer.writeln('Joblens Sync Log');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln();
    for (final log in logs) {
      buffer.writeln(
        '[${log.createdAt.toIso8601String()}] ${log.level.name.toUpperCase()} ${log.event}'
        '${log.assetId == null ? '' : ' asset=${log.assetId}'}'
        '${log.projectId == null ? '' : ' project=${log.projectId}'}'
        ' ${log.message}',
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final file = File(
      '${directory.path}/joblens_sync_log_${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    await file.writeAsString(buffer.toString());
    return file;
  }

  Future<void> clearSyncLog() async {
    await _runBusy(() async {
      await _database.clearSyncLogs();
      _syncLogs = const [];
      _notifyListenersIfActive();
    });
  }

  Future<void> setProjectSortMode(ProjectSortMode mode) async {
    if (_projectSortMode == mode) {
      return;
    }
    _projectSortMode = mode;
    await _database.setProjectSortMode(mode);
    _notifyListenersIfActive();
  }

  Future<void> setAppThemeMode(AppThemeMode mode) async {
    if (_appThemeMode == mode) {
      return;
    }
    _appThemeMode = mode;
    await _database.setAppThemeMode(mode);
    _notifyListenersIfActive();
  }

  Future<void> setLibraryImportMode(LibraryImportMode mode) async {
    if (_libraryImportMode == mode) {
      return;
    }
    _libraryImportMode = mode;
    await _database.setLibraryImportMode(mode);
    _notifyListenersIfActive();
  }

  Future<({int copiedCount, int skippedCount})> copyAssetsToPhoneStorage(
    Iterable<PhotoAsset> assets,
  ) async {
    var copiedCount = 0;
    var skippedCount = 0;

    await _runBusy(() async {
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!permission.hasAccess) {
        throw const ApiException(
          code: 'phone_storage_permission_denied',
          message:
              'Allow photo library access before copying photos to phone storage.',
        );
      }

      for (final asset in assets) {
        if (asset.existsInPhoneStorage) {
          skippedCount += 1;
          continue;
        }
        if (asset.localPath.trim().isEmpty) {
          skippedCount += 1;
          continue;
        }

        final file = File(asset.localPath);
        if (!file.existsSync()) {
          skippedCount += 1;
          continue;
        }

        await PhotoManager.editor.saveImageWithPath(
          file.path,
          title: p.basename(file.path),
          creationDate: asset.createdAt,
        );
        await _database.setAssetExistsInPhoneStorage(asset.id, true);
        copiedCount += 1;
      }

      await _hydrateLocalState();
      _notifyListenersIfActive();
    });

    return (copiedCount: copiedCount, skippedCount: skippedCount);
  }

  Future<String?> resolveThumbnailUrl(
    PhotoAsset asset, {
    bool forceRefresh = false,
  }) {
    return _syncService.getThumbnailUrl(asset, forceRefresh: forceRefresh);
  }

  Future<String?> resolveDownloadUrl(
    PhotoAsset asset, {
    bool forceRefresh = false,
  }) {
    return _syncService.getDownloadUrl(asset, forceRefresh: forceRefresh);
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_isBusy) {
      return;
    }

    _isBusy = true;
    _lastError = null;
    _notifyListenersIfActive();

    try {
      await action();
    } catch (error, stackTrace) {
      await _handleError(error);
      if (!_requiresReauthentication(error)) {
        _lastError = error.toString();
      }
      if (kDebugMode) {
        debugPrint('JoblensStore error: $error\n$stackTrace');
      }
    } finally {
      _isBusy = false;
      _notifyListenersIfActive();
    }
  }

  int get _defaultProjectId {
    final inbox = _projects
        .where((project) => project.name == 'Inbox')
        .toList();
    if (inbox.isNotEmpty) {
      return inbox.first.id;
    }
    if (_projects.isNotEmpty) {
      return _projects.first.id;
    }
    throw StateError('No project available');
  }

  Future<void> _hydrateLocalState() async {
    _assets = await _database.getAssets();
    _projects = await _database.getProjects();
    _projectCounts = await _database.getProjectCounts();
    _providers = await _database.getProviderAccounts();
    _syncJobs = await _database.getSyncJobs();
    _syncLogs = await _database.getSyncLogs();
    _projectSortMode = await _database.getProjectSortMode();
    _appThemeMode = await _database.getAppThemeMode();
    _libraryImportMode = await _database.getLibraryImportMode();
  }

  Future<void> _runBackgroundSyncRefresh() {
    return _queueBackgroundCloudWork(processQueue: true, refresh: true);
  }

  Future<void> _queueBackgroundCloudWork({
    Future<void> Function()? action,
    bool processQueue = false,
    bool refresh = false,
  }) {
    _pendingBackgroundSync = _pendingBackgroundSync.then((_) async {
      if (_isDisposed) {
        return;
      }
      try {
        if (action != null) {
          await action();
        }
        if (processQueue) {
          final projects = await _database.getProjects();
          await _syncService.processQueue(projects);
        }
        if (_isDisposed) {
          return;
        }
        if (refresh) {
          await this.refresh();
        }
      } catch (error, stackTrace) {
        if (_isDisposed) {
          return;
        }
        await _handleError(error);
        if (!_requiresReauthentication(error)) {
          _lastError = error.toString();
        }
        if (kDebugMode) {
          debugPrint('Background sync refresh failed: $error\n$stackTrace');
        }
        _notifyListenersIfActive();
      }
    });
    return _pendingBackgroundSync;
  }

  void _notifyListenersIfActive() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> _synchronizeAuthUser(String? userId) async {
    final normalizedUserId = userId?.trim();
    final storedUserId = await _database.getStoredAuthUserId();
    final shouldResetLocalData =
        storedUserId != null && storedUserId != normalizedUserId;

    if (shouldResetLocalData) {
      await _database.clearUserScopedData();
      await _mediaStorage.clearAll();
    }

    if (storedUserId != normalizedUserId) {
      await _database.setStoredAuthUserId(normalizedUserId);
    }

    await _database.normalizeAssetMediaPaths(_mediaStorage.rootDir.path);
    await _database.ensureDefaultProject();
    await _database.ensureProviderRows();
    await refresh();
  }

  Future<void> _handleError(Object error) async {
    if (!_requiresReauthentication(error)) {
      return;
    }

    _reauthenticationRequestCount += 1;
    _lastError = const ApiException(
      code: 'reauthentication_required',
      message: 'Cloud sync needs you to sign in again.',
      statusCode: 401,
    ).toString();
  }

  bool _requiresReauthentication(Object error) {
    if (error is! ApiException) {
      return false;
    }

    if (error.isAuthMissing) {
      return true;
    }

    if (error.statusCode == 401 || error.statusCode == 403) {
      return true;
    }

    return error.code == 'unauthorized';
  }

  Future<File?> _resolveLibraryAssetFile(
    AssetEntity entity,
    Directory tempDir,
  ) async {
    final originFile = await entity.originFile;
    if (originFile != null && originFile.existsSync()) {
      return originFile;
    }

    final file = await entity.file;
    if (file != null && file.existsSync()) {
      return file;
    }

    final bytes = await entity.originBytes;
    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    final title = await entity.titleAsync;
    final extension = title.contains('.')
        ? '.${title.split('.').last}'
        : '.jpg';
    final tempFile = File(
      '${tempDir.path}/${entity.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}$extension',
    );
    await tempFile.writeAsBytes(bytes, flush: true);
    return tempFile;
  }

  List<Project> _sortProjects(List<Project> projects, ProjectSortMode mode) {
    final sorted = List<Project>.from(projects);
    sorted.sort((a, b) {
      final aIsInbox = a.name == 'Inbox';
      final bIsInbox = b.name == 'Inbox';
      if (aIsInbox && !bIsInbox) {
        return -1;
      }
      if (!aIsInbox && bIsInbox) {
        return 1;
      }

      if (mode == ProjectSortMode.startDate) {
        final aDate = a.startDate;
        final bDate = b.startDate;
        if (aDate != null && bDate != null) {
          final byDate = aDate.compareTo(bDate);
          if (byDate != 0) {
            return byDate;
          }
        } else if (aDate != null) {
          return -1;
        } else if (bDate != null) {
          return 1;
        }
      }

      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) {
        return byName;
      }
      return a.id.compareTo(b.id);
    });
    return sorted;
  }
}

String normalizeProjectNotesForSave(String notes) {
  var normalized = notes.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  for (var i = 0; i < lines.length; i++) {
    lines[i] = lines[i].replaceFirst(RegExp(r'[ \t]+$'), '');
  }
  normalized = lines.join('\n');
  return normalized;
}

String _normalizeProjectNotesForSave(String notes) =>
    normalizeProjectNotesForSave(notes);

DateTime? _normalizeProjectStartDate(DateTime? startDate) {
  if (startDate == null) {
    return null;
  }
  return DateTime(startDate.year, startDate.month, startDate.day);
}
