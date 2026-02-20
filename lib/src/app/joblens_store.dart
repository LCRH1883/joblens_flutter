import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/db/app_database.dart';
import '../core/models/cloud_provider.dart';
import '../core/models/photo_asset.dart';
import '../core/models/project.dart';
import '../core/models/provider_account.dart';
import '../core/models/provider_credentials.dart';
import '../core/models/sync_job.dart';
import '../core/storage/media_storage_service.dart';
import '../core/sync/oauth/oauth_service.dart';
import '../core/sync/sync_service.dart';

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
    required OAuthService oauthService,
    ImagePicker? imagePicker,
  }) : _database = database,
       _mediaStorage = mediaStorage,
       _syncService = syncService,
       _oauthService = oauthService,
       _picker = imagePicker ?? ImagePicker();

  final AppDatabase _database;
  final MediaStorageService _mediaStorage;
  final SyncService _syncService;
  final OAuthService _oauthService;
  final ImagePicker _picker;

  bool _isLoading = true;
  bool _isBusy = false;
  String? _lastError;

  List<PhotoAsset> _assets = const [];
  List<Project> _projects = const [];
  Map<int, int> _projectCounts = const {};
  List<ProviderAccount> _providers = const [];
  List<SyncJob> _syncJobs = const [];
  Map<CloudProviderType, bool> _credentialStatus = {
    for (final provider in CloudProviderType.values) provider: false,
  };

  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get lastError => _lastError;
  List<PhotoAsset> get assets => _assets;
  List<Project> get projects => _projects;
  Map<int, int> get projectCounts => _projectCounts;
  List<ProviderAccount> get providers => _providers;
  List<SyncJob> get syncJobs => _syncJobs;
  Map<CloudProviderType, bool> get credentialStatus => _credentialStatus;

  Future<void> initialize() async {
    await _database.ensureDefaultProject();
    await _database.ensureProviderRows();
    await refresh();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> refresh() async {
    _assets = await _database.getAssets();
    _projects = await _database.getProjects();
    _projectCounts = await _database.getProjectCounts();
    _providers = await _database.getProviderAccounts();
    _syncJobs = await _database.getSyncJobs();
    _credentialStatus = await _syncService.credentialStatus();
    notifyListeners();
  }

  Future<void> ingestCapturedFile(File sourceFile, {int? projectId}) async {
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
      await _syncService.processQueue(_projects);
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
      await _database.createProject(trimmed);
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
      await refresh();
    });
  }

  Future<void> deleteProject(int projectId) async {
    if (projectId == _defaultProjectId) {
      return;
    }

    await _runBusy(() async {
      await _database.deleteProject(
        projectId,
        fallbackProjectId: _defaultProjectId,
      );
      await refresh();
    });
  }

  Future<void> moveAssetToProject(String assetId, int projectId) async {
    await _runBusy(() async {
      await _database.moveAssetToProject(assetId, projectId);
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

  Future<ProviderCredentials?> getProviderCredentials(
    CloudProviderType provider,
  ) async {
    return _syncService.readCredentials(provider);
  }

  Future<void> saveProviderCredentials(ProviderCredentials credentials) async {
    await _runBusy(() async {
      await _syncService.saveCredentials(credentials);
      _credentialStatus = await _syncService.credentialStatus();
      notifyListeners();
    });
  }

  Future<void> clearProviderCredentials(CloudProviderType provider) async {
    await _runBusy(() async {
      await _syncService.clearCredentials(provider);
      await _database.setProviderConnection(
        provider,
        ProviderTokenState.disconnected,
      );
      await _syncService.pauseProvider(provider);
      await refresh();
    });
  }

  Future<void> setProviderConnected(
    CloudProviderType provider,
    bool isConnected,
  ) async {
    await _runBusy(() async {
      await _setProviderConnectedInternal(provider, isConnected);
    });
  }

  Future<void> connectProviderWithOAuth(CloudProviderType provider) async {
    await _runBusy(() async {
      final credentials = await _oauthService.authorize(provider);
      await _syncService.saveCredentials(credentials);
      await _setProviderConnectedInternal(provider, true);
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

  Future<void> _setProviderConnectedInternal(
    CloudProviderType provider,
    bool isConnected,
  ) async {
    if (isConnected) {
      await _syncService.validateProviderConnection(provider);
    }

    await _database.setProviderConnection(
      provider,
      isConnected
          ? ProviderTokenState.connected
          : ProviderTokenState.disconnected,
    );

    if (isConnected) {
      await _syncService.resumeProvider(provider);
      final allAssets = await _database.getAssets();
      for (final asset in allAssets) {
        await _database.enqueueSyncJob(
          assetId: asset.id,
          projectId: asset.projectId,
          provider: provider,
        );
      }
    } else {
      await _syncService.pauseProvider(provider);
    }

    await refresh();
  }
}
