import '../db/app_database.dart';
import '../models/cloud_provider.dart';
import '../models/photo_asset.dart';
import '../models/project.dart';
import '../models/provider_credentials.dart';
import '../models/sync_job.dart';
import 'adapters/adapter_factory.dart';
import 'cloud_adapter.dart';
import 'credential_store.dart';
import 'oauth/oauth_service.dart';

class SyncService {
  SyncService(this._db, this._credentialStore, this._oauthService);

  final AppDatabase _db;
  final CredentialStore _credentialStore;
  final OAuthService _oauthService;
  bool _isRunning = false;
  static const Duration _refreshSkew = Duration(minutes: 2);

  Future<void> enqueueAsset(PhotoAsset asset) async {
    final providers = await _db.getConnectedProviders();
    for (final provider in providers) {
      await _db.enqueueSyncJob(
        assetId: asset.id,
        projectId: asset.projectId,
        provider: provider,
      );
    }
  }

  Future<void> enqueueProjectBackfill(
    Project project,
    List<PhotoAsset> assets,
  ) async {
    final providers = await _db.getConnectedProviders();
    for (final asset in assets.where((item) => item.projectId == project.id)) {
      for (final provider in providers) {
        await _db.enqueueSyncJob(
          assetId: asset.id,
          projectId: project.id,
          provider: provider,
        );
      }
    }
  }

  Future<void> pauseProvider(CloudProviderType provider) async {
    final jobs = await _db.getSyncJobs();
    for (final job in jobs.where(
      (item) =>
          item.providerType == provider &&
          (item.state == SyncJobState.queued ||
              item.state == SyncJobState.failed),
    )) {
      await _db.updateSyncJob(job.copyWith(state: SyncJobState.paused));
    }
  }

  Future<void> resumeProvider(CloudProviderType provider) async {
    final jobs = await _db.getSyncJobs();
    for (final job in jobs.where(
      (item) =>
          item.providerType == provider && item.state == SyncJobState.paused,
    )) {
      await _db.updateSyncJob(
        job.copyWith(state: SyncJobState.queued, lastError: null),
      );
    }
  }

  Future<void> retryFailed() async {
    await _db.setAllFailedToQueued();
  }

  Future<void> validateProviderConnection(CloudProviderType provider) async {
    final creds = await _ensureUsableCredentials(
      provider,
      throwOnRefreshFailure: true,
    );
    final adapter = buildAdapter(creds);
    if (adapter == null) {
      throw CloudSyncException(
        '${provider.label} credentials are missing or incomplete.',
      );
    }

    await adapter.authenticate();
  }

  Future<ProviderCredentials?> readCredentials(CloudProviderType provider) {
    return _credentialStore.read(provider);
  }

  Future<void> saveCredentials(ProviderCredentials credentials) async {
    await _credentialStore.save(credentials.provider, credentials);
  }

  Future<void> clearCredentials(CloudProviderType provider) async {
    await _credentialStore.clear(provider);
  }

  Future<Map<CloudProviderType, bool>> credentialStatus() {
    return _credentialStore.hasCredentials();
  }

  Future<void> processQueue(List<Project> projects) async {
    if (_isRunning) {
      return;
    }

    _isRunning = true;
    try {
      final pending = await _db.getPendingSyncJobs();
      if (pending.isEmpty) {
        return;
      }

      final adapters = await _buildAdapters();
      final projectMap = {for (final project in projects) project.id: project};

      for (final job in pending) {
        if (job.state == SyncJobState.paused) {
          continue;
        }

        final adapter = adapters[job.providerType];
        final asset = await _db.getAssetById(job.assetId);
        final project = projectMap[job.projectId];

        if (adapter == null || asset == null || project == null) {
          await _db.updateSyncJob(
            job.copyWith(
              state: SyncJobState.failed,
              attemptCount: job.attemptCount + 1,
              lastError: 'Missing adapter, credentials, asset, or project',
            ),
          );
          continue;
        }

        try {
          await _db.updateSyncJob(job.copyWith(state: SyncJobState.uploading));
          await adapter.uploadFile(asset: asset, project: project);
          await _db.updateSyncJob(
            job.copyWith(
              state: SyncJobState.done,
              attemptCount: job.attemptCount + 1,
              lastError: null,
            ),
          );
        } catch (error) {
          await _db.updateSyncJob(
            job.copyWith(
              state: SyncJobState.failed,
              attemptCount: job.attemptCount + 1,
              lastError: error.toString(),
            ),
          );
        }
      }
    } finally {
      _isRunning = false;
    }
  }

  Future<Map<CloudProviderType, CloudAdapter>> _buildAdapters() async {
    final map = <CloudProviderType, CloudAdapter>{};

    for (final provider in CloudProviderType.values) {
      final credentials = await _ensureUsableCredentials(provider);
      final adapter = buildAdapter(credentials);
      if (adapter != null) {
        map[provider] = adapter;
      }
    }

    return map;
  }

  Future<ProviderCredentials?> _ensureUsableCredentials(
    CloudProviderType provider, {
    bool throwOnRefreshFailure = false,
  }) async {
    var credentials = await _credentialStore.read(provider);
    if (credentials == null) {
      return null;
    }

    if (provider == CloudProviderType.nextcloud) {
      return credentials.isConfigured ? credentials : null;
    }

    if (!credentials.hasAccessToken) {
      credentials = await _tryRefresh(
        provider,
        credentials,
        throwOnFailure: throwOnRefreshFailure,
      );
      return credentials;
    }

    if (credentials.isAccessTokenExpiringSoon(skew: _refreshSkew) &&
        credentials.canRefreshAccessToken) {
      credentials = await _tryRefresh(
        provider,
        credentials,
        throwOnFailure: throwOnRefreshFailure,
      );
    }

    return credentials;
  }

  Future<ProviderCredentials?> _tryRefresh(
    CloudProviderType provider,
    ProviderCredentials current, {
    bool throwOnFailure = false,
  }) async {
    if (!current.canRefreshAccessToken) {
      return null;
    }

    try {
      final refreshed = await _oauthService.refreshAccessToken(current);
      await _credentialStore.save(provider, refreshed);
      return refreshed;
    } catch (_) {
      if (throwOnFailure) {
        rethrow;
      }
      return null;
    }
  }
}
