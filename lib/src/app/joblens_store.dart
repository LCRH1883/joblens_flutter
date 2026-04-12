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
import '../core/api/backend_api_models.dart';
import '../core/models/app_launch_destination.dart';
import '../core/models/app_theme_mode.dart';
import '../core/models/capture_target_preference.dart';
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
  int _forcedSignOutNoticeCount = 0;
  String? _forcedSignOutMessage;
  bool _isRecoveringMissingDeviceSession = false;
  Future<void> _pendingBackgroundSync = Future.value();
  Future<void> _pendingLocalIngest = Future.value();
  ProjectSortMode _projectSortMode = ProjectSortMode.name;
  AppLaunchDestination _appLaunchDestination = AppLaunchDestination.camera;
  AppThemeMode _appThemeMode = AppThemeMode.system;
  LibraryImportMode _libraryImportMode = LibraryImportMode.copy;
  CaptureTargetPreference _captureTargetPreference =
      CaptureTargetPreference.defaults;
  bool _hasStoredAppLaunchDestination = false;

  List<PhotoAsset> _assets = const [];
  Map<String, AssetSyncStatus> _assetSyncStatuses = const {};
  List<Project> _projects = const [];
  Map<int, int> _projectCounts = const {};
  List<ProviderAccount> _providers = const [];
  List<SignedInDevice> _signedInDevices = const [];
  List<SyncJob> _syncJobs = const [];
  List<SyncLogEntry> _syncLogs = const [];

  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get lastError => _lastError;
  int get reauthenticationRequestCount => _reauthenticationRequestCount;
  int get forcedSignOutNoticeCount => _forcedSignOutNoticeCount;
  String? get forcedSignOutMessage => _forcedSignOutMessage;
  List<PhotoAsset> get assets => _assets;
  AssetSyncStatus assetSyncStatusFor(String assetId) =>
      _assetSyncStatuses[assetId] ?? AssetSyncStatus.local;
  List<Project> get projects => _sortProjects(_projects, _projectSortMode);
  Map<int, int> get projectCounts => _projectCounts;
  List<ProviderAccount> get providers => _providers;
  List<SignedInDevice> get signedInDevices => _signedInDevices;
  List<SyncJob> get syncJobs => _syncJobs;
  List<SyncLogEntry> get syncLogs => _syncLogs;
  ProjectSortMode get projectSortMode => _projectSortMode;
  AppLaunchDestination get appLaunchDestination => _appLaunchDestination;
  AppThemeMode get appThemeMode => _appThemeMode;
  LibraryImportMode get libraryImportMode => _libraryImportMode;
  CaptureTargetPreference get captureTargetPreference =>
      _captureTargetPreference;

  AppLaunchDestination launchDestinationForSession({
    required bool isAuthenticated,
  }) {
    if (isAuthenticated && !_hasStoredAppLaunchDestination) {
      return AppLaunchDestination.projects;
    }
    return _appLaunchDestination;
  }

  Future<void> initialize() async {
    await _synchronizeAuthUser(_currentAuthUserIdProvider?.call());
    _isLoading = false;
    _notifyListenersIfActive();
  }

  Future<void> syncAuthSession(Session? session) async {
    final sessionUserId = session?.user.id.trim();
    final currentUserId = _currentAuthUserIdProvider?.call()?.trim();
    final effectiveUserId = (sessionUserId != null && sessionUserId.isNotEmpty)
        ? sessionUserId
        : (currentUserId != null && currentUserId.isNotEmpty)
        ? currentUserId
        : null;
    if (effectiveUserId != null) {
      _lastError = null;
    }
    await _synchronizeAuthUser(
      effectiveUserId,
      allowClearingForNull: effectiveUserId == null,
    );
    if (effectiveUserId != null) {
      await registerCurrentDeviceSession(refreshDevicesAfterRegister: true);
    } else {
      _signedInDevices = const [];
      _notifyListenersIfActive();
    }
  }

  Future<bool> registerCurrentDeviceSession({
    bool refreshDevicesAfterRegister = false,
  }) async {
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      return false;
    }
    var registered = false;
    try {
      await _syncService.registerCurrentDevice();
      registered = true;
      _lastError = null;
      if (refreshDevicesAfterRegister) {
        final response = await _syncService.listSignedInDevices();
        final devices = response.devices.toList(growable: false)
          ..sort((a, b) {
            if (a.isCurrent != b.isCurrent) {
              return a.isCurrent ? -1 : 1;
            }
            final aSeen = a.lastSeenAt?.millisecondsSinceEpoch ?? 0;
            final bSeen = b.lastSeenAt?.millisecondsSinceEpoch ?? 0;
            return bSeen.compareTo(aSeen);
          });
        _signedInDevices = devices;
      }
    } catch (error, stackTrace) {
      await _handleError(error);
      if (!_requiresReauthentication(error) && !_requiresForcedLogout(error)) {
        _lastError = error.toString();
      }
      if (kDebugMode) {
        debugPrint('Device registration failed: $error\n$stackTrace');
      }
    }
    _notifyListenersIfActive();
    return registered;
  }

  Future<void> checkCurrentSessionStatus() async {
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      return;
    }
    try {
      final status = await _syncService.getSessionStatus();
      if (status.isRevoked) {
        await _forceLocalSignOut(
          status.message ?? 'You were signed out from another device.',
        );
        return;
      }
      if (status.registrationRequired) {
        await registerCurrentDeviceSession();
      }
    } catch (error, stackTrace) {
      await _handleError(error);
      if (!_requiresReauthentication(error) && !_requiresForcedLogout(error)) {
        _lastError = error.toString();
      }
      if (kDebugMode) {
        debugPrint('Session status check failed: $error\n$stackTrace');
      }
      _notifyListenersIfActive();
    }
  }

  Future<void> signOut() async {
    await _runBusy(() async {
      final signOutAction = _signOutAction;
      if (signOutAction != null) {
        await signOutAction();
      }
      await _synchronizeAuthUser(null, allowClearingForNull: true);
    });
  }

  Future<void> refreshSignedInDevices() async {
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      _signedInDevices = const [];
      _notifyListenersIfActive();
      return;
    }

    try {
      await registerCurrentDeviceSession(refreshDevicesAfterRegister: false);
      final response = await _syncService.listSignedInDevices();
      final devices = response.devices.toList(growable: false)
        ..sort((a, b) {
          if (a.isCurrent != b.isCurrent) {
            return a.isCurrent ? -1 : 1;
          }
          final aSeen = a.lastSeenAt?.millisecondsSinceEpoch ?? 0;
          final bSeen = b.lastSeenAt?.millisecondsSinceEpoch ?? 0;
          return bSeen.compareTo(aSeen);
        });
      _signedInDevices = devices;
      _lastError = null;
    } catch (error, stackTrace) {
      await _handleError(error);
      if (!_requiresReauthentication(error) && !_requiresForcedLogout(error)) {
        _lastError = error.toString();
      }
      if (kDebugMode) {
        debugPrint('Signed-in device refresh failed: $error\n$stackTrace');
      }
    }
    _notifyListenersIfActive();
  }

  Future<void> signOutDeviceSession(String deviceId) async {
    await _runBusy(() async {
      final previousDevices = _signedInDevices;
      _signedInDevices = _signedInDevices
          .where((device) => device.deviceId != deviceId)
          .toList(growable: false);
      _notifyListenersIfActive();
      try {
        await _syncService.signOutDevice(deviceId);
        await refreshSignedInDevices();
      } catch (_) {
        _signedInDevices = previousDevices;
        rethrow;
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
    await _hydrateLocalState(includeDiagnostics: false);
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      _lastError = null;
      _notifyListenersIfActive();
      return;
    }
    _notifyListenersIfActive();
    unawaited(
      _kickSync(forceBootstrap: !await _database.hasCompletedBootstrap()),
    );
  }

  Future<void> ingestCapturedFile(
    File sourceFile, {
    int? projectId,
    bool processSyncNow = false,
  }) async {
    _lastError = null;
    final targetProjectId = projectId ?? _defaultProjectId;
    final asset = _createPendingAssetShell(
      sourceType: AssetSourceType.captured,
      projectId: targetProjectId,
    );
    await _database.insertPendingAssetShell(asset);
    _insertAssetIntoState(asset);
    _notifyListenersIfActive();
    await _enqueueLocalIngest(() async {
      await _finalizePendingAssetIngest(
        asset,
        sourceFile: sourceFile,
        existsInPhoneStorage: false,
      );
      if (_isDisposed) {
        return;
      }
      if (processSyncNow) {
        await _syncService.kick();
        if (_isDisposed) {
          return;
        }
        await _hydrateLocalState(includeDiagnostics: false);
        _notifyListenersIfActive();
      } else {
        unawaited(_kickSync());
      }
    });
  }

  Future<void> importFromPhoneGallery({int? projectId}) async {
    _lastError = null;
    final selectedFiles = await _picker.pickMultiImage(imageQuality: 100);
    if (selectedFiles.isEmpty) {
      return;
    }

    final targetProjectId = projectId ?? _defaultProjectId;
    final pendingImports = <(PhotoAsset, File)>[];
    for (final selected in selectedFiles) {
      final source = File(selected.path);
      if (!source.existsSync()) {
        continue;
      }
      final asset = _createPendingAssetShell(
        sourceType: AssetSourceType.imported,
        projectId: targetProjectId,
      );
      await _database.insertPendingAssetShell(asset);
      pendingImports.add((asset, source));
      _insertAssetIntoState(asset);
    }
    _notifyListenersIfActive();
    if (pendingImports.isEmpty) {
      return;
    }

    unawaited(
      _enqueueLocalIngest(() async {
        for (final entry in pendingImports) {
          await _finalizePendingAssetIngest(
            entry.$1,
            sourceFile: entry.$2,
            existsInPhoneStorage: true,
          );
        }
        unawaited(_kickSync());
      }),
    );
  }

  Future<void> importFromPhoneLibraryAssets(
    List<AssetEntity> assets, {
    int? projectId,
    required LibraryImportMode mode,
  }) async {
    _lastError = null;
    if (assets.isEmpty) {
      return;
    }

    final targetProjectId = projectId ?? _defaultProjectId;
    final tempDir = await getTemporaryDirectory();
    final pendingImports = <(PhotoAsset, AssetEntity)>[];
    for (final entity in assets) {
      final asset = _createPendingAssetShell(
        sourceType: AssetSourceType.imported,
        projectId: targetProjectId,
        createdAt: entity.createDateTime,
      );
      await _database.insertPendingAssetShell(asset);
      pendingImports.add((asset, entity));
      _insertAssetIntoState(asset);
    }
    _notifyListenersIfActive();
    if (pendingImports.isEmpty) {
      return;
    }

    unawaited(
      _enqueueLocalIngest(() async {
        final importedAssetIds = <String>[];
        for (final entry in pendingImports) {
          final source = await _resolveLibraryAssetFile(entry.$2, tempDir);
          if (source == null || !source.existsSync()) {
            await _discardPendingAsset(entry.$1.id, entry.$1.projectId);
            continue;
          }
          final completed = await _finalizePendingAssetIngest(
            entry.$1,
            sourceFile: source,
            existsInPhoneStorage: mode == LibraryImportMode.copy,
          );
          if (completed && mode == LibraryImportMode.move) {
            importedAssetIds.add(entry.$2.id);
          }
        }

        if (mode == LibraryImportMode.move && importedAssetIds.isNotEmpty) {
          await PhotoManager.editor.deleteWithIds(importedAssetIds);
        }

        unawaited(_kickSync());
      }),
    );
  }

  Future<void> createProject(String name, {DateTime? startDate}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    _lastError = null;
    try {
      final normalizedStartDate = _normalizeProjectStartDate(startDate);
      final projectId = await _database.createProject(
        trimmed,
        startDate: normalizedStartDate,
      );
      final project = await _database.getProjectById(projectId);
      if (project != null) {
        _upsertProjectInState(project);
        _projectCounts = <int, int>{..._projectCounts, project.id: 0};
        _notifyListenersIfActive();
      }
      unawaited(_kickSync());
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
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

    _lastError = null;
    try {
      final existing = await _database.getProjectById(projectId);
      if (existing == null) {
        return;
      }
      final normalizedStartDate = _normalizeProjectStartDate(startDate);
      final normalizedName = existing.name == 'Inbox' ? 'Inbox' : trimmed;
      await _database.updateProjectMetadata(
        projectId,
        name: normalizedName,
        startDate: normalizedStartDate,
      );
      final updated = await _database.getProjectById(projectId);
      if (updated != null) {
        _upsertProjectInState(updated);
      }
      _notifyListenersIfActive();
      unawaited(_kickSync());
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
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

    _lastError = null;
    try {
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
      _projects = _projects
          .where((item) => item.id != projectId)
          .toList(growable: false);
      _assets = _assets
          .map((asset) {
            if (movedAssetIds.contains(asset.id)) {
              return asset.copyWith(projectId: _defaultProjectId);
            }
            return asset;
          })
          .toList(growable: false);
      _projectCounts = await _database.getProjectCounts();
      await _refreshAssetSyncStatuses();
      _notifyListenersIfActive();
      if (movedAssetIds.isNotEmpty || project.remoteProjectId != null) {
        unawaited(_kickSync());
      }
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
  }

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    _lastError = null;
    try {
      await _database.moveAssetToProject(assetId, projectId);
      _moveAssetInState(assetId, projectId);
      await _refreshAssetSyncStatuses();
      _notifyListenersIfActive();
      unawaited(_kickSync());
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
  }

  Future<void> moveAssetsToProject(
    Iterable<String> assetIds,
    int projectId,
  ) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return;
    }

    _lastError = null;
    try {
      for (final assetId in uniqueIds) {
        await _database.moveAssetToProject(assetId, projectId);
        _moveAssetInState(assetId, projectId);
      }
      await _refreshAssetSyncStatuses();
      _notifyListenersIfActive();
      unawaited(_kickSync());
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
  }

  Future<void> softDeleteAsset(String assetId) async {
    _lastError = null;
    try {
      final asset = await _database.getAssetById(assetId);
      await _database.softDeleteAsset(assetId);
      if (asset != null) {
        _removeAssetFromState(asset.id, asset.projectId);
      }
      _notifyListenersIfActive();
      if (asset != null) {
        unawaited(_kickSync());
      }
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
  }

  Future<void> softDeleteAssets(Iterable<String> assetIds) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return;
    }

    _lastError = null;
    try {
      final assets = await _database.getAssetsByIds(uniqueIds);
      for (final assetId in uniqueIds) {
        await _database.softDeleteAsset(assetId);
      }
      for (final asset in assets) {
        _removeAssetFromState(asset.id, asset.projectId);
      }
      _notifyListenersIfActive();
      if (assets.isNotEmpty) {
        unawaited(_kickSync());
      }
    } catch (error, stackTrace) {
      await _recordForegroundError(error, stackTrace);
    }
  }

  Future<void> disconnectProvider(CloudProviderType provider) async {
    await _runBusy(() async {
      await _syncService.disconnectProvider(provider);
      await _hydrateLocalState();
      _notifyListenersIfActive();
      unawaited(_kickSync(forceBootstrap: true));
    });
  }

  Future<String?> beginProviderConnection(CloudProviderType provider) async {
    String? authUrl;
    await _runBusy(() async {
      final activeProvider = _activeProviderAccount;
      final intent = activeProvider == null
          ? 'connect'
          : activeProvider.providerType == provider
          ? 'reconnect'
          : 'switch';
      authUrl = await _syncService.beginProviderConnection(
        provider,
        intent: intent,
        oldConnectionId: activeProvider?.connectionId,
      );
    });
    return authUrl;
  }

  Future<void> completeProviderConnection(String sessionId) async {
    await _runBusy(() async {
      await _syncService.completeProviderConnection(sessionId);
      await _syncService.refreshProviderConnections();
      await _hydrateLocalState(includeDiagnostics: false);
      _notifyListenersIfActive();
      unawaited(
        _scheduleBackgroundSyncAction(() async {
          await _syncService.reconcileProjects(
            _projects.where(
              (project) => project.remoteProjectId?.trim().isNotEmpty ?? false,
            ),
          );
          await _syncService.kick(forceBootstrap: true);
        }),
      );
    });
  }

  Future<void> backfillCloudSyncAfterProviderConnection() async {
    await _runBusy(() async {
      await _syncService.refreshProviderConnections();
      await _syncService.retryFailed();
      await _hydrateLocalState(includeDiagnostics: false);
      _notifyListenersIfActive();
      unawaited(
        _scheduleBackgroundSyncAction(() async {
          await _syncService.reconcileProjects(
            _projects.where(
              (project) => project.remoteProjectId?.trim().isNotEmpty ?? false,
            ),
          );
          await _syncService.kick(forceBootstrap: true);
        }),
      );
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
      await _hydrateLocalState(includeDiagnostics: false);
      _notifyListenersIfActive();
      unawaited(
        _scheduleBackgroundSyncAction(() async {
          await _syncService.reconcileProjects(
            _projects.where(
              (project) => project.remoteProjectId?.trim().isNotEmpty ?? false,
            ),
          );
          await _syncService.kick(forceBootstrap: true);
        }),
      );
    });
  }

  Future<void> runSyncNow() async {
    await _runBusy(() async {
      await _syncService.kick(forceBootstrap: true);
      await _hydrateLocalState();
      _notifyListenersIfActive();
    });
  }

  Future<void> retryFailedSyncJobs() async {
    await _runBusy(() async {
      await _syncService.retryFailed();
      await _syncService.kick();
      await _hydrateLocalState();
      _notifyListenersIfActive();
    });
  }

  Future<bool> reconcileProject(Project project) async {
    if (project.remoteProjectId?.trim().isEmpty ?? true) {
      return false;
    }
    _lastError = null;
    _notifyListenersIfActive();
    unawaited(
      _scheduleBackgroundSyncAction(() async {
        await _syncService.reconcileProject(project);
        await _syncService.kick();
      }),
    );
    return true;
  }

  Future<int> reconcileAllProjects() async {
    final syncableProjects = _projects
        .where((project) => project.remoteProjectId?.trim().isNotEmpty ?? false)
        .toList(growable: false);
    if (syncableProjects.isEmpty) {
      return 0;
    }
    _lastError = null;
    _notifyListenersIfActive();
    unawaited(
      _scheduleBackgroundSyncAction(() async {
        await _syncService.reconcileProjects(syncableProjects);
        await _syncService.kick();
      }),
    );
    return syncableProjects.length;
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

  Future<void> setAppLaunchDestination(AppLaunchDestination destination) async {
    if (_hasStoredAppLaunchDestination &&
        _appLaunchDestination == destination) {
      return;
    }
    _appLaunchDestination = destination;
    _hasStoredAppLaunchDestination = true;
    await _database.setAppLaunchDestination(destination);
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

  ResolvedCaptureTarget resolveCaptureTarget() {
    final currentProjects = projects;
    final inbox =
        _findProjectByName(currentProjects, 'Inbox') ??
        (currentProjects.isNotEmpty ? currentProjects.first : null);
    if (inbox == null) {
      throw StateError('No project available');
    }

    final fixed = _findProjectById(
      currentProjects,
      _captureTargetPreference.fixedProjectId,
    );

    return switch (_captureTargetPreference.mode) {
      CaptureTargetMode.inbox => ResolvedCaptureTarget(
        projectId: inbox.id,
        projectName: inbox.name,
      ),
      CaptureTargetMode.fixedProject when fixed != null =>
        ResolvedCaptureTarget(projectId: fixed.id, projectName: fixed.name),
      _ => ResolvedCaptureTarget(projectId: inbox.id, projectName: inbox.name),
    };
  }

  Future<void> updateCaptureTargetPreference({
    required CaptureTargetMode mode,
    int? fixedProjectId,
  }) async {
    final normalizedMode = switch (mode) {
      CaptureTargetMode.fixedProject when fixedProjectId != null =>
        CaptureTargetMode.fixedProject,
      CaptureTargetMode.fixedProject => CaptureTargetMode.inbox,
      CaptureTargetMode.lastUsed when fixedProjectId != null =>
        CaptureTargetMode.fixedProject,
      CaptureTargetMode.lastUsed => CaptureTargetMode.inbox,
      _ => CaptureTargetMode.inbox,
    };
    _captureTargetPreference = _captureTargetPreference.copyWith(
      mode: normalizedMode,
      fixedProjectId: normalizedMode == CaptureTargetMode.fixedProject
          ? fixedProjectId
          : null,
      clearFixedProjectId: normalizedMode != CaptureTargetMode.fixedProject,
      clearLastUsedProjectId: true,
    );
    _notifyListenersIfActive();
    await _database.setCaptureTargetMode(normalizedMode);
    await _database.setCaptureFixedProjectId(
      normalizedMode == CaptureTargetMode.fixedProject ? fixedProjectId : null,
    );
    await _database.setCaptureLastUsedProjectId(null);
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

  Project? _findProjectById(List<Project> currentProjects, int? projectId) {
    if (projectId == null) {
      return null;
    }
    for (final project in currentProjects) {
      if (project.id == projectId) {
        return project;
      }
    }
    return null;
  }

  Project? _findProjectByName(List<Project> currentProjects, String name) {
    for (final project in currentProjects) {
      if (project.name == name) {
        return project;
      }
    }
    return null;
  }

  Future<void> _hydrateLocalState({bool includeDiagnostics = true}) async {
    _assets = await _database.getAssets();
    _projects = await _database.getProjects();
    _projectCounts = await _database.getProjectCounts();
    _providers = await _database.getProviderAccounts();
    await _refreshAssetSyncStatuses();
    _projectSortMode = await _database.getProjectSortMode();
    final storedAppLaunchDestination =
        await _database.getStoredAppLaunchDestination();
    _hasStoredAppLaunchDestination = storedAppLaunchDestination != null;
    _appLaunchDestination =
        storedAppLaunchDestination ?? AppLaunchDestination.camera;
    _appThemeMode = await _database.getAppThemeMode();
    _libraryImportMode = await _database.getLibraryImportMode();
    _captureTargetPreference = await _database.getCaptureTargetPreference();
    if (includeDiagnostics) {
      _syncJobs = await _database.getSyncJobs();
      _syncLogs = await _database.getSyncLogs();
    }
  }

  Future<void> _kickSync({bool forceBootstrap = false}) {
    return _scheduleBackgroundSyncAction(
      () => _syncService.kick(forceBootstrap: forceBootstrap),
    );
  }

  Future<void> _scheduleBackgroundSyncAction(Future<void> Function() action) {
    _pendingBackgroundSync = _pendingBackgroundSync.then((_) async {
      if (_isDisposed) {
        return;
      }
      final authUserId = _currentAuthUserIdProvider?.call();
      if (authUserId == null || authUserId.trim().isEmpty) {
        _lastError = null;
        await _hydrateLocalState(includeDiagnostics: false);
        _notifyListenersIfActive();
        return;
      }
      try {
        await action();
        if (_isDisposed) {
          return;
        }
        _lastError = null;
        await _hydrateLocalState(includeDiagnostics: false);
      } catch (error, stackTrace) {
        if (_isDisposed) {
          return;
        }
        await _handleError(error);
        if (!_requiresReauthentication(error)) {
          _lastError = error.toString();
        }
        if (kDebugMode) {
          debugPrint('Background sync failed: $error\n$stackTrace');
        }
      }
      _notifyListenersIfActive();
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
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    super.dispose();
  }

  @visibleForTesting
  Future<void> waitForIdle() async {
    await _pendingLocalIngest;
    await _pendingBackgroundSync;
  }

  Future<void> _synchronizeAuthUser(
    String? userId, {
    bool allowClearingForNull = false,
  }) async {
    final normalizedUserId = userId?.trim();
    final storedUserId = await _database.getStoredAuthUserId();
    final storedLaunchDestination =
        await _database.getStoredAppLaunchDestination();
    final shouldResetForUserSwitch =
        storedUserId != null &&
        normalizedUserId != null &&
        storedUserId != normalizedUserId;
    final shouldResetForSignOut =
        allowClearingForNull &&
        storedUserId != null &&
        normalizedUserId == null;
    final shouldResetLocalData =
        shouldResetForUserSwitch || shouldResetForSignOut;
    final shouldSeedProjectsLaunchDestination =
        storedLaunchDestination == null &&
        storedUserId == null &&
        normalizedUserId != null;

    if (shouldResetLocalData) {
      await _database.clearUserScopedData();
      await _mediaStorage.clearAll();
      _signedInDevices = const [];
    }

    if (storedUserId != normalizedUserId) {
      await _database.setStoredAuthUserId(normalizedUserId);
    }

    if (shouldSeedProjectsLaunchDestination) {
      await _database.setAppLaunchDestination(AppLaunchDestination.projects);
    }

    await _database.normalizeAssetMediaPaths(_mediaStorage.rootDir.path);
    await _database.ensureDefaultProject();
    await _database.ensureProviderRows();
    await refresh();
  }

  Future<void> _handleError(Object error) async {
    if (_requiresForcedLogout(error)) {
      await _forceLocalSignOut('You were signed out from another device.');
      return;
    }
    if (await _recoverMissingDeviceSession(error)) {
      return;
    }
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

  bool _requiresForcedLogout(Object error) {
    if (error is! ApiException) {
      return false;
    }
    return error.code == 'device_session_revoked' ||
        error.code == 'auth_session_invalid';
  }

  bool _requiresDeviceSessionRegistration(Object error) {
    if (error is! ApiException) {
      return false;
    }
    return error.code == 'device_session_missing';
  }

  Future<bool> _recoverMissingDeviceSession(Object error) async {
    if (!_requiresDeviceSessionRegistration(error)) {
      return false;
    }
    if (_isRecoveringMissingDeviceSession) {
      return true;
    }
    _isRecoveringMissingDeviceSession = true;
    try {
      await registerCurrentDeviceSession();
      return true;
    } finally {
      _isRecoveringMissingDeviceSession = false;
    }
  }

  Future<void> _forceLocalSignOut(String message) async {
    final signOutAction = _signOutAction;
    if (signOutAction != null) {
      try {
        await signOutAction();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Forced local sign-out failed: $error');
        }
      }
    }
    _forcedSignOutMessage = message;
    _forcedSignOutNoticeCount += 1;
    _lastError = null;
    await _synchronizeAuthUser(null, allowClearingForNull: true);
    _notifyListenersIfActive();
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

  Future<void> _enqueueLocalIngest(Future<void> Function() action) {
    _pendingLocalIngest = _pendingLocalIngest.then((_) async {
      if (_isDisposed) {
        return;
      }
      await action();
    });
    return _pendingLocalIngest;
  }

  PhotoAsset _createPendingAssetShell({
    required AssetSourceType sourceType,
    required int projectId,
    DateTime? createdAt,
  }) {
    final now = DateTime.now();
    final id = _mediaStorage.createAssetId();
    return PhotoAsset(
      id: id,
      localPath: '',
      thumbPath: '',
      createdAt: createdAt ?? now,
      importedAt: now,
      projectId: projectId,
      hash: 'pending:$id',
      status: AssetStatus.active,
      sourceType: sourceType,
      cloudState: AssetCloudState.localAndCloud,
      existsInPhoneStorage: false,
      ingestState: AssetIngestState.pending,
    );
  }

  Future<bool> _finalizePendingAssetIngest(
    PhotoAsset shell, {
    required File sourceFile,
    required bool existsInPhoneStorage,
  }) async {
    try {
      if (_isDisposed) {
        return false;
      }
      final stored = await _mediaStorage.ingestIntoStorage(
        assetId: shell.id,
        source: sourceFile,
      );
      if (_isDisposed) {
        return false;
      }
      final existingDuplicate = await _database.getAssetByHash(
        stored.hash,
        excludingAssetId: shell.id,
      );
      if (existingDuplicate != null &&
          existingDuplicate.status == AssetStatus.active) {
        if (!_isDisposed) {
          await _discardPendingAsset(shell.id, shell.projectId);
        }
        return true;
      }

      if (_isDisposed) {
        return false;
      }
      await _database.finalizePendingAssetIngest(
        assetId: shell.id,
        localPath: stored.localPath,
        thumbPath: stored.thumbPath,
        hash: stored.hash,
        existsInPhoneStorage: existsInPhoneStorage,
        cloudState: AssetCloudState.localAndCloud,
      );
      if (_isDisposed) {
        return false;
      }
      final updated = await _database.getAssetById(shell.id);
      if (updated != null) {
        _replaceAssetInState(updated);
        await _refreshAssetSyncStatuses();
        _notifyListenersIfActive();
      }
      return true;
    } catch (error, stackTrace) {
      if (!_isDisposed) {
        await _database.markAssetIngestFailed(
          shell.id,
          errorCode: 'local_ingest_failed',
        );
        await _discardPendingAsset(shell.id, shell.projectId);
        await _recordForegroundError(error, stackTrace);
      }
      return false;
    }
  }

  Future<void> _discardPendingAsset(String assetId, int projectId) async {
    if (_isDisposed) {
      return;
    }
    await _database.purgeAsset(assetId);
    _removeAssetFromState(assetId, projectId);
    _notifyListenersIfActive();
  }

  Future<void> _recordForegroundError(
    Object error,
    StackTrace stackTrace,
  ) async {
    await _handleError(error);
    if (!_requiresReauthentication(error)) {
      _lastError = error.toString();
    }
    if (kDebugMode) {
      debugPrint('JoblensStore error: $error\n$stackTrace');
    }
    _notifyListenersIfActive();
  }

  void _insertAssetIntoState(PhotoAsset asset) {
    _assets = [asset, ..._assets.where((item) => item.id != asset.id)];
    _projectCounts = <int, int>{
      ..._projectCounts,
      asset.projectId: (_projectCounts[asset.projectId] ?? 0) + 1,
    };
    _assetSyncStatuses = <String, AssetSyncStatus>{
      ..._assetSyncStatuses,
      asset.id: _deriveAssetSyncStatus(asset),
    };
  }

  void _replaceAssetInState(PhotoAsset asset) {
    final index = _assets.indexWhere((item) => item.id == asset.id);
    if (index < 0) {
      _insertAssetIntoState(asset);
      return;
    }
    final updated = List<PhotoAsset>.from(_assets);
    updated[index] = asset;
    _assets = updated;
    _assetSyncStatuses = <String, AssetSyncStatus>{
      ..._assetSyncStatuses,
      asset.id: _deriveAssetSyncStatus(asset),
    };
  }

  void _removeAssetFromState(String assetId, int projectId) {
    final removed = _assets.any((item) => item.id == assetId);
    _assets = _assets
        .where((item) => item.id != assetId)
        .toList(growable: false);
    final nextStatuses = Map<String, AssetSyncStatus>.from(_assetSyncStatuses);
    nextStatuses.remove(assetId);
    _assetSyncStatuses = nextStatuses;
    if (!removed) {
      return;
    }
    final nextCount = (_projectCounts[projectId] ?? 1) - 1;
    _projectCounts = <int, int>{
      ..._projectCounts,
      projectId: nextCount < 0 ? 0 : nextCount,
    };
  }

  void _moveAssetInState(String assetId, int projectId) {
    final index = _assets.indexWhere((item) => item.id == assetId);
    if (index < 0) {
      return;
    }
    final current = _assets[index];
    if (current.projectId == projectId) {
      return;
    }
    final updated = List<PhotoAsset>.from(_assets);
    updated[index] = current.copyWith(projectId: projectId);
    _assets = updated;
    _assetSyncStatuses = <String, AssetSyncStatus>{
      ..._assetSyncStatuses,
      assetId: _deriveAssetSyncStatus(updated[index]),
    };
    _projectCounts = <int, int>{
      ..._projectCounts,
      current.projectId: ((_projectCounts[current.projectId] ?? 1) - 1).clamp(
        0,
        1 << 30,
      ),
      projectId: (_projectCounts[projectId] ?? 0) + 1,
    };
  }

  void _upsertProjectInState(Project project) {
    final index = _projects.indexWhere((item) => item.id == project.id);
    if (index < 0) {
      _projects = [..._projects, project];
      return;
    }
    final updated = List<Project>.from(_projects);
    updated[index] = project;
    _projects = updated;
  }

  Future<void> _refreshAssetSyncStatuses() async {
    final syncJobStates = await _database.getAssetSyncJobStates(
      _assets.map((asset) => asset.id),
    );
    final activeConnectionId = _activeProviderAccount?.connectionId?.trim();
    final mirrorStates =
        activeConnectionId != null && activeConnectionId.isNotEmpty
        ? await _database.getAssetProviderMirrorStatuses(
            assetIds: _assets.map((asset) => asset.id),
            providerConnectionId: activeConnectionId,
          )
        : const <String, String>{};
    _assetSyncStatuses = {
      for (final asset in _assets)
        asset.id: _deriveAssetSyncStatus(
          asset,
          syncJobState: syncJobStates[asset.id],
          activeMirrorStatus: mirrorStates[asset.id],
        ),
    };
  }

  AssetSyncStatus _deriveAssetSyncStatus(
    PhotoAsset asset, {
    SyncJobState? syncJobState,
    String? activeMirrorStatus,
  }) {
    final activeProvider = _activeProviderAccount;
    final remoteProvider = asset.remoteProvider?.trim();
    final remoteAssetId = asset.remoteAssetId?.trim();
    if (asset.ingestState == AssetIngestState.failed ||
        (asset.lastSyncErrorCode?.trim().isNotEmpty ?? false)) {
      return AssetSyncStatus.failed;
    }
    if (syncJobState == SyncJobState.failed) {
      return AssetSyncStatus.failed;
    }
    if (asset.cloudState == AssetCloudState.cloudOnly) {
      return AssetSyncStatus.cloudOnly;
    }
    if (asset.ingestState == AssetIngestState.pending ||
        syncJobState == SyncJobState.queued ||
        syncJobState == SyncJobState.uploading) {
      return AssetSyncStatus.syncing;
    }
    switch (activeMirrorStatus) {
      case 'failed':
        return AssetSyncStatus.failed;
      case 'pending':
        return AssetSyncStatus.syncing;
      case 'mirrored':
        if (asset.localPath.trim().isNotEmpty) {
          return AssetSyncStatus.synced;
        }
        return AssetSyncStatus.cloudOnly;
      case 'deleted':
        return asset.localPath.trim().isNotEmpty
            ? AssetSyncStatus.local
            : AssetSyncStatus.cloudOnly;
    }
    if (activeProvider != null && (remoteAssetId?.isNotEmpty ?? false)) {
      return AssetSyncStatus.syncing;
    }
    if ((remoteAssetId?.isNotEmpty ?? false) &&
        asset.localPath.trim().isNotEmpty &&
        activeProvider != null &&
        remoteProvider != null &&
        remoteProvider.isNotEmpty &&
        remoteProvider != activeProvider.providerType.key) {
      return AssetSyncStatus.syncing;
    }
    if ((remoteAssetId?.isNotEmpty ?? false) &&
        asset.localPath.trim().isNotEmpty) {
      if (activeProvider == null) {
        return AssetSyncStatus.synced;
      }
      return AssetSyncStatus.synced;
    }
    return AssetSyncStatus.local;
  }

  ProviderAccount? get _activeProviderAccount {
    for (final provider in _providers) {
      if (provider.hasActiveConnection) {
        return provider;
      }
    }
    return null;
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
