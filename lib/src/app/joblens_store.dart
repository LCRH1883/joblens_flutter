import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session;

import '../core/db/app_database.dart';
import '../core/models/cloud_provider.dart';
import '../core/models/photo_asset.dart';
import '../core/models/project.dart';
import '../core/models/provider_account.dart';
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
  String? _lastError;

  List<PhotoAsset> _assets = const [];
  List<Project> _projects = const [];
  Map<int, int> _projectCounts = const {};
  List<ProviderAccount> _providers = const [];
  List<SyncJob> _syncJobs = const [];

  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get lastError => _lastError;
  List<PhotoAsset> get assets => _assets;
  List<Project> get projects => _projects;
  Map<int, int> get projectCounts => _projectCounts;
  List<ProviderAccount> get providers => _providers;
  List<SyncJob> get syncJobs => _syncJobs;

  Future<void> initialize() async {
    await _synchronizeAuthUser(_currentAuthUserIdProvider?.call());
    _isLoading = false;
    notifyListeners();
  }

  Future<void> syncAuthSession(Session? session) async {
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

  Future<void> refresh() async {
    await _hydrateLocalState();
    final authUserId = _currentAuthUserIdProvider?.call();
    if (authUserId == null || authUserId.trim().isEmpty) {
      _lastError = null;
      notifyListeners();
      return;
    }

    String? remoteMergeError;
    try {
      await _syncService.refreshProviderConnections();
    } catch (error, stackTrace) {
      remoteMergeError = error.toString();
      if (kDebugMode) {
        debugPrint('Provider refresh failed: $error\n$stackTrace');
      }
    }
    _assets = await _database.getAssets();
    _projects = await _database.getProjects();
    _projectCounts = await _database.getProjectCounts();
    _providers = await _database.getProviderAccounts();
    _syncJobs = await _database.getSyncJobs();
    try {
      await _syncService.mergeRemoteAssets(_projects);
      _assets = await _database.getAssets();
      _projects = await _database.getProjects();
      _projectCounts = await _database.getProjectCounts();
      _syncJobs = await _database.getSyncJobs();
    } catch (error, stackTrace) {
      remoteMergeError = error.toString();
      if (kDebugMode) {
        debugPrint('Remote merge failed: $error\n$stackTrace');
      }
    }
    if (remoteMergeError != null) {
      _lastError = remoteMergeError;
    }
    notifyListeners();
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
      if (processSyncNow) {
        await _syncService.processQueue(_projects);
      } else {
        unawaited(_syncService.processQueue(_projects));
      }
      await refresh();
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
        await _syncService.enqueueAsset(asset);
      }

      await _syncService.processQueue(_projects);
      await refresh();
    });
  }

  Future<void> createProject(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _runBusy(() async {
      final projectId = await _database.createProject(trimmed);
      final localProject = Project(
        id: projectId,
        name: trimmed,
        notes: '',
        remoteProjectId: null,
        coverAssetId: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        syncFolderMap: const {},
      );
      await _syncService.syncProject(localProject);
      await refresh();
    });
  }

  Future<void> renameProject(int projectId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }

    await _runBusy(() async {
      await _database.renameProject(projectId, trimmed);
      final project = (await _database.getProjects()).firstWhere(
        (item) => item.id == projectId,
      );
      await _syncService.syncProject(project);
      await refresh();
    });
  }

  Future<void> updateProjectNotes(int projectId, String notes) async {
    final normalized = _normalizeProjectNotesForSave(notes);
    if (normalized.length > kProjectNotesMaxLength) {
      _lastError =
          'Project notes must be at most $kProjectNotesMaxLength characters.';
      notifyListeners();
      return;
    }
    await _runBusy(() async {
      await _database.updateProjectNotes(projectId, normalized);
      await refresh();
    });
  }

  Future<void> updateProjectRemoteId(
    int projectId,
    String? remoteProjectId,
  ) async {
    await _runBusy(() async {
      await _database.updateProjectRemoteId(projectId, remoteProjectId);
      await refresh();
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
      final updatedAssets = await _database.getAssets();
      await _syncService.enqueueAssets(
        updatedAssets.where((asset) => movedAssetIds.contains(asset.id)),
      );
      unawaited(_syncService.processQueue(await _database.getProjects()));
      await refresh();
    });
  }

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    await _runBusy(() async {
      await _database.moveAssetToProject(assetId, projectId);
      final movedAsset = await _database.getAssetById(assetId);
      if (movedAsset != null) {
        await _syncService.enqueueAsset(movedAsset);
        unawaited(_syncService.processQueue(await _database.getProjects()));
      }
      await refresh();
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
      unawaited(_syncService.processQueue(await _database.getProjects()));
      await refresh();
    });
  }

  Future<void> softDeleteAsset(String assetId) async {
    await _runBusy(() async {
      await _database.softDeleteAsset(assetId);
      await refresh();
    });
  }

  Future<void> softDeleteAssets(Iterable<String> assetIds) async {
    final uniqueIds = assetIds.toSet();
    if (uniqueIds.isEmpty) {
      return;
    }

    await _runBusy(() async {
      for (final assetId in uniqueIds) {
        await _database.softDeleteAsset(assetId);
      }
      await refresh();
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
    notifyListeners();

    try {
      await action();
    } catch (error, stackTrace) {
      _lastError = error.toString();
      if (kDebugMode) {
        debugPrint('JoblensStore error: $error\n$stackTrace');
      }
    } finally {
      _isBusy = false;
      notifyListeners();
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

    await _database.ensureDefaultProject();
    await _database.ensureProviderRows();
    await refresh();
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
