import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/api/api_exception.dart';
import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/models/provider_account.dart';
import 'package:joblens_flutter/src/core/models/project.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'asset synced through a different provider shows as syncing after provider switch',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_switch_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: _ProviderSwitchSyncService(database),
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      final projectId = await database.ensureDefaultProject();
      await database.ensureProviderRows();
      await database.updateProviderAccountStatus(
        CloudProviderType.dropbox,
        connectionStatus: ProviderConnectionStatus.ready,
        displayName: 'Dropbox',
        accountIdentifier: 'jane@example.com',
        isActive: true,
      );
      await database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-1',
          localPath: '/tmp/asset-1.jpg',
          thumbPath: '/tmp/asset-1-thumb.jpg',
          createdAt: DateTime(2026, 4, 8),
          importedAt: DateTime(2026, 4, 8),
          projectId: projectId,
          hash: 'a' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: true,
          remoteAssetId: 'remote-asset-1',
          remoteProvider: CloudProviderType.oneDrive.key,
          remoteFileId: 'provider-file-1',
          uploadPath: 'Joblens/Inbox/asset-1.jpg',
        ),
      );

      await store.initialize();

      expect(store.assetSyncStatusFor('asset-1'), AssetSyncStatus.syncing);
    },
  );

  test(
    'asset synced through the active provider shows synced without mirror rows',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_active_status_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: _ProviderSwitchSyncService(database),
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      final projectId = await database.ensureDefaultProject();
      await database.ensureProviderRows();
      await database.updateProviderAccountStatus(
        CloudProviderType.dropbox,
        connectionStatus: ProviderConnectionStatus.ready,
        displayName: 'Dropbox',
        accountIdentifier: 'jane@example.com',
        isActive: true,
      );
      await database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-1',
          localPath: '/tmp/asset-1.jpg',
          thumbPath: '/tmp/asset-1-thumb.jpg',
          createdAt: DateTime(2026, 4, 8),
          importedAt: DateTime(2026, 4, 8),
          projectId: projectId,
          hash: 'a' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: true,
          remoteAssetId: 'remote-asset-1',
          remoteProvider: CloudProviderType.dropbox.key,
          remoteFileId: 'provider-file-1',
          uploadPath: 'Joblens/Inbox/asset-1.jpg',
        ),
      );

      await store.initialize();

      expect(store.assetSyncStatusFor('asset-1'), AssetSyncStatus.synced);
    },
  );

  test(
    'provider connection backfill schedules project reconcile before sync kick',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_backfill_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database);
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await database.ensureDefaultProject();
      await database.ensureProviderRows();
      final syncedProjectId = await database.createProject('Library');
      await database.markProjectSynced(
        syncedProjectId,
        remoteProjectId: 'remote-project-1',
        remoteRev: 1,
      );

      syncService.onRefreshProviderConnections = () async {
        await database.updateProviderAccountStatus(
          CloudProviderType.dropbox,
          connectionStatus: ProviderConnectionStatus.ready,
          displayName: 'Dropbox',
          accountIdentifier: 'jane@example.com',
          isActive: true,
        );
      };

      await store.initialize();
      await store.backfillCloudSyncAfterProviderConnection();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(syncService.reconcileCalls, greaterThanOrEqualTo(1));
      expect(syncService.lastReconciledProjectIds, ['remote-project-1']);
      expect(syncService.kickCalls, greaterThanOrEqualTo(1));
      expect(syncService.lastKickForceBootstrap, isTrue);
    },
  );

  test(
    'provider connection stores backfill progress from session result and mirror rows',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_provider_progress_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..providerAuthSessionResult = const ProviderAuthSessionResult(
          sessionId: 'session-1',
          status: 'completed',
          provider: CloudProviderType.dropbox,
          intent: 'switch',
          connectionId: 'conn-1',
          connectionStatus: 'connected_bootstrapping',
          projectsPending: 4,
          assetsPending: 9,
        );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      final projectId = await database.createProject('Library');
      await database.ensureProviderRows();
      await database.insertPendingAssetShell(
        PhotoAsset(
          id: 'asset-1',
          localPath: '/tmp/asset-1.jpg',
          thumbPath: '/tmp/asset-1-thumb.jpg',
          createdAt: DateTime(2026, 4, 12),
          importedAt: DateTime(2026, 4, 12),
          projectId: projectId,
          hash: 'a' * 64,
          status: AssetStatus.active,
          sourceType: AssetSourceType.imported,
          cloudState: AssetCloudState.localAndCloud,
          existsInPhoneStorage: true,
        ),
      );
      await database.upsertProjectProviderMirror(
        localProjectId: projectId,
        providerConnectionId: 'conn-1',
        status: 'pending',
      );
      await database.upsertAssetProviderMirror(
        assetId: 'asset-1',
        providerConnectionId: 'conn-1',
        status: 'failed',
      );

      syncService.onRefreshProviderConnections = () async {
        await database.updateProviderAccountStatus(
          CloudProviderType.dropbox,
          connectionStatus: ProviderConnectionStatus.connectedBootstrapping,
          connectionId: 'conn-1',
          displayName: 'Dropbox',
          accountIdentifier: 'jane@example.com',
          isActive: true,
        );
      };

      await store.initialize();
      await store.completeProviderConnection('session-1');

      final progress = store.providerBackfillProgress;
      expect(progress, isNotNull);
      expect(progress!.provider, CloudProviderType.dropbox);
      expect(progress.projectsPending, 4);
      expect(progress.assetsPending, 9);
      expect(progress.projectFailures, 0);
      expect(progress.assetFailures, 1);
    },
  );

  test(
    'disconnected provider does not expose stale account identity',
    () async {
      final account = ProviderAccount(
        id: 'dropbox',
        providerType: CloudProviderType.dropbox,
        displayName: 'Jane Dropbox',
        accountIdentifier: 'jane@example.com',
        connectionStatus: ProviderConnectionStatus.disconnected,
        connectedAt: DateTime(2026, 4, 10),
        isActive: false,
      );

      expect(account.hasActiveConnection, isFalse);
      expect(account.connectedAccountLabel, isNull);
    },
  );

  test('revoked device session forces local sign-out', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_device_session_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    final mediaStorage = await MediaStorageService.create(
      rootDirectory: tempDir,
    );
    final syncService = _ProviderSwitchSyncService(database)
      ..sessionStatus = const SessionStatusResponse(
        status: 'revoked',
        reason: 'remote_user_signout',
        message: 'You were signed out from another device.',
      );
    String? currentUserId = 'test-user';
    var signOutCalls = 0;
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: syncService,
      currentAuthUserIdProvider: () => currentUserId,
      signOutAction: () async {
        signOutCalls += 1;
        currentUserId = null;
      },
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.checkCurrentSessionStatus();

    expect(signOutCalls, 1);
    expect(store.forcedSignOutNoticeCount, 1);
    expect(
      store.forcedSignOutMessage,
      'You were signed out from another device.',
    );
  });

  test('missing device session triggers one re-registration attempt', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_device_session_missing_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    final mediaStorage = await MediaStorageService.create(
      rootDirectory: tempDir,
    );
    final syncService = _ProviderSwitchSyncService(database)
      ..listDevicesError = const ApiException(
        code: 'device_session_missing',
        message: 'Register this device session before continuing.',
        statusCode: 401,
      );
    final store = JoblensStore(
      database: database,
      mediaStorage: mediaStorage,
      syncService: syncService,
      currentAuthUserIdProvider: () => 'test-user',
    );
    addTearDown(() async {
      await store.waitForIdle();
      store.dispose();
      await database.close();
    });

    await store.initialize();
    await store.refresh();
    syncService.registerDeviceCalls = 0;

    await store.refreshSignedInDevices();

    expect(syncService.registerDeviceCalls, 2);
    expect(store.reauthenticationRequestCount, 0);
  });

  test(
    'failed re-registration keeps user signed in and surfaces warning',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_device_session_missing_failure_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..listDevicesError = const ApiException(
          code: 'device_session_missing',
          message: 'Register this device session before continuing.',
          statusCode: 401,
        )
        ..registerDeviceError = const ApiException(
          code: 'device_register_failed',
          message: 'backend down',
          statusCode: 500,
        );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.refresh();
      syncService.registerDeviceCalls = 0;

      await store.refreshSignedInDevices();

      expect(syncService.registerDeviceCalls, 2);
      expect(store.reauthenticationRequestCount, 0);
      expect(store.lastError, contains('backend down'));
    },
  );

  test(
    'auth sync registers current device and refreshes signed-in devices',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_device_list_refresh_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..devicesResponse = SignedInDevicesResponse(
          devices: [
            SignedInDevice(
              deviceId: 'device-1',
              deviceName: 'This iPhone',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 10),
              lastSeenAt: DateTime(2026, 4, 11, 11),
              lastSyncAt: DateTime(2026, 4, 11, 11),
              isCurrent: true,
              canSignOut: false,
            ),
            SignedInDevice(
              deviceId: 'device-2',
              deviceName: 'Other iPad',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 9),
              lastSeenAt: DateTime(2026, 4, 11, 10),
              lastSyncAt: null,
              isCurrent: false,
              canSignOut: true,
            ),
          ],
        );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.syncAuthSession(_session('test-user'));

      expect(syncService.registerDeviceCalls, 1);
      expect(syncService.listDevicesCalls, 1);
      expect(store.signedInDevices, hasLength(2));
      expect(store.signedInDevices.first.deviceId, 'device-1');
    },
  );

  test(
    'concurrent auth sync requests share one device registration for the same user',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_auth_sync_queue_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..registerDeviceGate = Completer<void>();
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();

      final first = store.syncAuthSession(_session('test-user'));
      final second = store.syncAuthSession(_session('test-user'));

      for (var i = 0; i < 20 && syncService.registerDeviceCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(syncService.registerDeviceCalls, 1);
      expect(syncService.maxConcurrentRegisterDeviceCalls, 1);

      syncService.registerDeviceGate!.complete();
      await Future.wait([first, second]);

      expect(syncService.registerDeviceCalls, 1);
      expect(syncService.listDevicesCalls, 1);
    },
  );

  test(
    'concurrent revoked session checks force one local sign-out and tolerate missing media storage',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_concurrent_sign_out_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..sessionStatus = const SessionStatusResponse(
          status: 'revoked',
          reason: 'remote_user_signout',
          message: 'You were signed out from another device.',
        );
      String? currentUserId = 'test-user';
      var signOutCalls = 0;
      final signOutGate = Completer<void>();
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => currentUserId,
        signOutAction: () async {
          signOutCalls += 1;
          await signOutGate.future;
          currentUserId = null;
        },
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await mediaStorage.rootDir.delete(recursive: true);

      final first = store.checkCurrentSessionStatus();
      final second = store.checkCurrentSessionStatus();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(signOutCalls, 1);

      signOutGate.complete();
      await Future.wait([first, second]);

      expect(signOutCalls, 1);
      expect(store.forcedSignOutNoticeCount, 1);
      expect(await mediaStorage.rootDir.exists(), isTrue);
    },
  );

  test(
    'remote device sign-out calls backend and refreshes signed-in devices',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_device_sign_out_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..devicesResponse = SignedInDevicesResponse(
          devices: [
            SignedInDevice(
              deviceId: 'device-1',
              deviceName: 'This iPhone',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 10),
              lastSeenAt: DateTime(2026, 4, 11, 11),
              lastSyncAt: DateTime(2026, 4, 11, 11),
              isCurrent: true,
              canSignOut: false,
            ),
            SignedInDevice(
              deviceId: 'device-2',
              deviceName: 'Other iPad',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 9),
              lastSeenAt: DateTime(2026, 4, 11, 10),
              lastSyncAt: null,
              isCurrent: false,
              canSignOut: true,
            ),
          ],
        );
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.syncAuthSession(_session('test-user'));

      syncService.devicesResponse = SignedInDevicesResponse(
        devices: [
          SignedInDevice(
            deviceId: 'device-1',
            deviceName: 'This iPhone',
            platform: 'ios',
            signedInAt: DateTime(2026, 4, 11, 10),
            lastSeenAt: DateTime(2026, 4, 11, 11),
            lastSyncAt: DateTime(2026, 4, 11, 11),
            isCurrent: true,
            canSignOut: false,
          ),
        ],
      );

      await store.signOutDeviceSession('device-2');

      expect(syncService.signOutDeviceCalls, 1);
      expect(syncService.lastSignedOutDeviceId, 'device-2');
      expect(store.signedInDevices.map((device) => device.deviceId), [
        'device-1',
      ]);
    },
  );

  test(
    'remote device sign-out restores device list when backend call fails',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_device_sign_out_failure_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'joblens.db');
      final database = await AppDatabase.open(databasePath: dbPath);
      final mediaStorage = await MediaStorageService.create(
        rootDirectory: tempDir,
      );
      final syncService = _ProviderSwitchSyncService(database)
        ..devicesResponse = SignedInDevicesResponse(
          devices: [
            SignedInDevice(
              deviceId: 'device-1',
              deviceName: 'This iPhone',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 10),
              lastSeenAt: DateTime(2026, 4, 11, 11),
              lastSyncAt: DateTime(2026, 4, 11, 11),
              isCurrent: true,
              canSignOut: false,
            ),
            SignedInDevice(
              deviceId: 'device-2',
              deviceName: 'Other iPad',
              platform: 'ios',
              signedInAt: DateTime(2026, 4, 11, 9),
              lastSeenAt: DateTime(2026, 4, 11, 10),
              lastSyncAt: null,
              isCurrent: false,
              canSignOut: true,
            ),
          ],
        )
        ..signOutDeviceError = Exception('backend failed');
      final store = JoblensStore(
        database: database,
        mediaStorage: mediaStorage,
        syncService: syncService,
        currentAuthUserIdProvider: () => 'test-user',
      );
      addTearDown(() async {
        await store.waitForIdle();
        store.dispose();
        await database.close();
      });

      await store.initialize();
      await store.syncAuthSession(_session('test-user'));

      await store.signOutDeviceSession('device-2');

      expect(syncService.signOutDeviceCalls, 1);
      expect(store.signedInDevices.map((device) => device.deviceId), [
        'device-1',
        'device-2',
      ]);
    },
  );
}

class _ProviderSwitchSyncService extends SyncService {
  _ProviderSwitchSyncService(super.db) : super();

  Future<void> Function()? onRefreshProviderConnections;
  ProviderAuthSessionResult providerAuthSessionResult =
      const ProviderAuthSessionResult(
        sessionId: 'session-1',
        status: 'completed',
        provider: CloudProviderType.dropbox,
      );
  int reconcileCalls = 0;
  int kickCalls = 0;
  int registerDeviceCalls = 0;
  int listDevicesCalls = 0;
  int signOutDeviceCalls = 0;
  bool lastKickForceBootstrap = false;
  String? lastSignedOutDeviceId;
  List<String> lastReconciledProjectIds = const [];
  Completer<void>? registerDeviceGate;
  Object? signOutDeviceError;
  Object? registerDeviceError;
  Object? listDevicesError;
  SessionStatusResponse sessionStatus = const SessionStatusResponse(
    status: 'active',
  );
  SignedInDevicesResponse devicesResponse = const SignedInDevicesResponse(
    devices: [],
  );
  int _activeRegisterDeviceCalls = 0;
  int maxConcurrentRegisterDeviceCalls = 0;

  @override
  Future<void> refreshProviderConnections() async {
    if (onRefreshProviderConnections != null) {
      await onRefreshProviderConnections!();
    }
  }

  @override
  Future<ProviderAuthSessionResult> completeProviderConnection(
    String sessionId,
  ) async {
    return providerAuthSessionResult;
  }

  @override
  Future<void> retryFailed() async {}

  @override
  Future<int> reconcileProjects(Iterable<Project> projects) async {
    reconcileCalls += 1;
    lastReconciledProjectIds = projects
        .map((project) => project.remoteProjectId)
        .whereType<String>()
        .toList(growable: false);
    return lastReconciledProjectIds.length;
  }

  @override
  Future<void> kick({bool forceBootstrap = false}) async {
    kickCalls += 1;
    lastKickForceBootstrap = forceBootstrap;
  }

  @override
  Future<RegisterDeviceResponse> registerCurrentDevice() async {
    registerDeviceCalls += 1;
    _activeRegisterDeviceCalls += 1;
    if (_activeRegisterDeviceCalls > maxConcurrentRegisterDeviceCalls) {
      maxConcurrentRegisterDeviceCalls = _activeRegisterDeviceCalls;
    }
    try {
      final gate = registerDeviceGate;
      if (gate != null && !gate.isCompleted) {
        await gate.future;
      }
      final error = registerDeviceError;
      if (error != null) {
        throw error;
      }
      return const RegisterDeviceResponse(
        deviceId: 'device-1',
        isCurrent: true,
        deviceSessionId: 'session-1',
      );
    } finally {
      _activeRegisterDeviceCalls -= 1;
    }
  }

  @override
  Future<SessionStatusResponse> getSessionStatus() async => sessionStatus;

  @override
  Future<SignedInDevicesResponse> listSignedInDevices() async {
    listDevicesCalls += 1;
    final error = listDevicesError;
    if (error != null) {
      throw error;
    }
    return devicesResponse;
  }

  @override
  Future<void> signOutDevice(String deviceId) async {
    signOutDeviceCalls += 1;
    lastSignedOutDeviceId = deviceId;
    final error = signOutDeviceError;
    if (error != null) {
      throw error;
    }
  }
}

Session _session(String userId) {
  return Session.fromJson({
    'access_token': 'not-a-jwt',
    'token_type': 'bearer',
    'refresh_token': 'refresh-token',
    'expires_in': 3600,
    'user': {
      'id': userId,
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'aud': 'authenticated',
      'email': '$userId@example.com',
      'created_at': DateTime(2026, 4, 11).toIso8601String(),
    },
  })!;
}
