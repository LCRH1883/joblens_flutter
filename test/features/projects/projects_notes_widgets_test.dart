import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';
import 'package:joblens_flutter/src/features/gallery/gallery_page.dart';
import 'package:joblens_flutter/src/features/gallery/photo_viewer_page.dart';
import 'package:joblens_flutter/src/features/projects/project_detail_page.dart';
import 'package:joblens_flutter/src/features/projects/projects_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('ProjectDetailPage opens notes editor with existing notes', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    await tester.runAsync(() => harness.store.createProject('Library One'));
    final project = harness.store.projects.firstWhere(
      (item) => item.name == 'Library One',
    );
    await tester.runAsync(
      () => harness.store.updateProjectNotes(project.id, 'Original note'),
    );
    final updatedProject = harness.store.projects.firstWhere(
      (item) => item.id == project.id,
    );

    await tester.pumpWidget(
      _wrapWithStore(harness.store, ProjectDetailPage(project: updatedProject)),
    );
    await tester.pump();

    final editNotesButton = find.byTooltip('Edit notes');
    expect(editNotesButton, findsOneWidget);

    _pressIconButton(tester, editNotesButton);
    await _pumpUntilFound(tester, find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Original note'), findsOneWidget);
  });

  testWidgets('ProjectsPage shows note preview only when notes exist', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    await tester.runAsync(() => harness.store.createProject('With note'));
    await tester.runAsync(() => harness.store.createProject('No note'));

    final withNote = harness.store.projects.firstWhere(
      (item) => item.name == 'With note',
    );
    final withoutNote = harness.store.projects.firstWhere(
      (item) => item.name == 'No note',
    );

    await tester.runAsync(
      () => harness.store.updateProjectNotes(
        withNote.id,
        'First line preview\nSecond line hidden',
      ),
    );
    await tester.runAsync(
      () => harness.store.updateProjectNotes(withoutNote.id, ''),
    );

    await tester.pumpWidget(
      _wrapWithStore(harness.store, const ProjectsPage()),
    );
    await tester.pump();

    expect(find.text('First line preview'), findsOneWidget);
    expect(find.text('Second line hidden'), findsNothing);
  });

  testWidgets('GalleryPage allows selecting photos from select mode', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    final source = File(p.join(harness.tempDir.path, 'capture.jpg'));
    await tester.runAsync(() => source.writeAsBytes(List<int>.filled(128, 7)));
    await tester.runAsync(
      () => harness.store.ingestCapturedFile(source, processSyncNow: true),
    );

    await tester.pumpWidget(_wrapWithStore(harness.store, const GalleryPage()));
    await tester.pump();

    await tester.tap(find.byTooltip('Select photos'));
    await tester.pump();
    await tester.tap(find.byType(Image).first);
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('GalleryPage hides cloud-only assets', (tester) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    final projectId = await tester.runAsync(
      () => harness.database.ensureDefaultProject(),
    );
    await tester.runAsync(
      () => harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-cloud-only',
        projectId: projectId!,
        remoteAssetId: 'remote-cloud-only',
        sha256: 'a' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/cloud-only.jpg',
      ),
    );
    await tester.runAsync(harness.store.refresh);

    await tester.pumpWidget(_wrapWithStore(harness.store, const GalleryPage()));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(
      find.text(
        'No photos on this device yet. Capture with Joblens or import from your phone gallery.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'ProjectsPage hydrates and reuses a persistent thumbnail for cloud-only covers',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      await tester.runAsync(() => harness.store.createProject('Thumb Project'));
      final project = harness.store.projects.firstWhere(
        (item) => item.name == 'Thumb Project',
      );
      harness
              .syncService
              .thumbnailBytesByRemoteAssetId['remote-project-thumb'] =
          _thumbnailBytes;
      await tester.runAsync(
        () => harness.database.upsertCloudOnlyAsset(
          localAssetId: 'asset-project-thumb',
          projectId: project.id,
          remoteAssetId: 'remote-project-thumb',
          sha256: 'b' * 64,
          createdAt: DateTime(2026, 4, 14),
          remotePath: 'Joblens/Thumb Project/thumb.jpg',
        ),
      );
      await tester.runAsync(harness.store.refresh);

      await tester.pumpWidget(
        _wrapWithStore(harness.store, const ProjectsPage()),
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () async =>
            (await tester.runAsync(
              () => harness.database.getAssetById('asset-project-thumb'),
            ))?.thumbPath.isNotEmpty ==
            true,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(harness.syncService.thumbnailRequests, ['remote-project-thumb']);
      final updated = await tester.runAsync(
        () => harness.database.getAssetById('asset-project-thumb'),
      );
      expect(updated, isNotNull);
      expect(updated!.thumbPath, isNotEmpty);
      expect(File(updated.thumbPath).existsSync(), isTrue);
    },
  );

  testWidgets('GalleryPage shows assets with a valid local original', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    final source = File(p.join(harness.tempDir.path, 'gallery-local.jpg'));
    await tester.runAsync(() => source.writeAsBytes(List<int>.filled(128, 4)));
    await tester.runAsync(
      () => harness.store.ingestCapturedFile(source, processSyncNow: true),
    );

    await tester.pumpWidget(_wrapWithStore(harness.store, const GalleryPage()));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(
      find.text(
        'No photos on this device yet. Capture with Joblens or import from your phone gallery.',
      ),
      findsNothing,
    );
  });

  testWidgets(
    'GalleryPage still hides cloud-only assets with a persisted thumbnail',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      final projectId = await tester.runAsync(
        () => harness.database.ensureDefaultProject(),
      );
      harness
              .syncService
              .thumbnailBytesByRemoteAssetId['remote-gallery-thumb'] =
          _thumbnailBytes;
      await tester.runAsync(
        () => harness.database.upsertCloudOnlyAsset(
          localAssetId: 'asset-gallery-thumb',
          projectId: projectId!,
          remoteAssetId: 'remote-gallery-thumb',
          sha256: 'c' * 64,
          createdAt: DateTime(2026, 4, 14),
          remotePath: 'Joblens/Inbox/gallery-thumb.jpg',
        ),
      );
      await tester.runAsync(harness.store.refresh);
      final asset = harness.store.assets.singleWhere(
        (item) => item.id == 'asset-gallery-thumb',
      );
      await tester.runAsync(
        () => harness.store.ensurePersistentThumbnail(asset),
      );

      await tester.pumpWidget(
        _wrapWithStore(harness.store, const GalleryPage()),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Image), findsNothing);
      expect(
        find.text(
          'No photos on this device yet. Capture with Joblens or import from your phone gallery.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('ProjectDetailPage supports selecting multiple photos', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    await tester.runAsync(
      () => harness.store.createProject('Selection Project'),
    );
    final project = harness.store.projects.firstWhere(
      (item) => item.name == 'Selection Project',
    );

    final sourceA = File(p.join(harness.tempDir.path, 'a.jpg'));
    final sourceB = File(p.join(harness.tempDir.path, 'b.jpg'));
    await tester.runAsync(
      () => sourceA.writeAsBytes(List<int>.generate(128, (i) => i % 255)),
    );
    await tester.runAsync(
      () =>
          sourceB.writeAsBytes(List<int>.generate(128, (i) => (i + 37) % 255)),
    );
    await tester.runAsync(
      () => harness.store.ingestCapturedFile(sourceA, projectId: project.id),
    );
    await tester.runAsync(
      () => harness.store.ingestCapturedFile(sourceB, projectId: project.id),
    );

    final latestProject = harness.store.projects.firstWhere(
      (item) => item.id == project.id,
    );
    await tester.pumpWidget(
      _wrapWithStore(harness.store, ProjectDetailPage(project: latestProject)),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Select photos'));
    await tester.pump();
    await tester.tap(find.byType(Image).at(0));
    await tester.pump();
    await tester.tap(find.byType(Image).at(1));
    await tester.pump();

    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets(
    'ProjectDetailPage hydrates and reuses a persistent thumbnail for cloud-only assets',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      await tester.runAsync(
        () => harness.store.createProject('Cloud Detail Project'),
      );
      final project = harness.store.projects.firstWhere(
        (item) => item.name == 'Cloud Detail Project',
      );
      harness.syncService.thumbnailBytesByRemoteAssetId['remote-detail-thumb'] =
          _thumbnailBytes;
      await tester.runAsync(
        () => harness.database.upsertCloudOnlyAsset(
          localAssetId: 'asset-detail-thumb',
          projectId: project.id,
          remoteAssetId: 'remote-detail-thumb',
          sha256: 'd' * 64,
          createdAt: DateTime(2026, 4, 14),
          remotePath: 'Joblens/Cloud Detail Project/detail-thumb.jpg',
        ),
      );
      await tester.runAsync(harness.store.refresh);

      await tester.pumpWidget(
        _wrapWithStore(harness.store, ProjectDetailPage(project: project)),
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () async =>
            (await tester.runAsync(
              () => harness.database.getAssetById('asset-detail-thumb'),
            ))?.thumbPath.isNotEmpty ==
            true,
        maxTicks: 100,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(harness.syncService.thumbnailRequests, ['remote-detail-thumb']);
      final updated = await tester.runAsync(
        () => harness.database.getAssetById('asset-detail-thumb'),
      );
      expect(updated, isNotNull);
      expect(updated!.thumbPath, isNotEmpty);
      expect(File(updated.thumbPath).existsSync(), isTrue);
    },
  );

  testWidgets('PhotoViewerPage shows download action for cloud-only assets', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    final projectId = await tester.runAsync(
      () => harness.database.ensureDefaultProject(),
    );
    await tester.runAsync(
      () => harness.database.upsertCloudOnlyAsset(
        localAssetId: 'asset-cloud',
        projectId: projectId!,
        remoteAssetId: 'remote-asset-cloud',
        sha256: 'e' * 64,
        createdAt: DateTime(2026, 4, 14),
        remotePath: 'Joblens/Inbox/cloud.jpg',
      ),
    );
    await tester.runAsync(harness.store.refresh);

    final asset = harness.store.assets.singleWhere(
      (item) => item.id == 'asset-cloud',
    );
    await tester.pumpWidget(
      _wrapWithStore(
        harness.store,
        PhotoViewerPage(assets: [asset], initialIndex: 0),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Download to Joblens'), findsOneWidget);
    expect(find.byTooltip('Archive in Joblens'), findsNothing);
  });

  testWidgets(
    'PhotoViewerPage shows archive action for assets with a local original',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      final source = File(p.join(harness.tempDir.path, 'viewer-archive.jpg'));
      await tester.runAsync(
        () => source.writeAsBytes(List<int>.filled(128, 6)),
      );
      await tester.runAsync(
        () => harness.store.ingestCapturedFile(source, processSyncNow: true),
      );

      final asset = harness.store.assets.single;
      await tester.pumpWidget(
        _wrapWithStore(
          harness.store,
          PhotoViewerPage(assets: [asset], initialIndex: 0),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Archive in Joblens'), findsOneWidget);
    },
  );

  testWidgets('GalleryPage selection toolbar shows download action', (
    tester,
  ) async {
    final harness = (await tester.runAsync(_createHarness))!;
    addTearDown(harness.dispose);

    final source = File(p.join(harness.tempDir.path, 'gallery-download.jpg'));
    await tester.runAsync(() => source.writeAsBytes(List<int>.filled(128, 9)));
    await tester.runAsync(
      () => harness.store.ingestCapturedFile(source, processSyncNow: true),
    );

    await tester.pumpWidget(_wrapWithStore(harness.store, const GalleryPage()));
    await tester.pump();

    await tester.tap(find.byTooltip('Select photos'));
    await tester.pump();
    await tester.tap(find.byType(Image).first);
    await tester.pump();

    expect(find.byTooltip('Archive selected'), findsOneWidget);
    expect(find.byTooltip('Download selected'), findsOneWidget);
  });

  testWidgets(
    'GalleryPage hides archived cloud-only assets and shows them again after download',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      final source = File(
        p.join(harness.tempDir.path, 'gallery-lifecycle.jpg'),
      );
      await tester.runAsync(
        () => source.writeAsBytes(List<int>.filled(128, 11)),
      );
      await tester.runAsync(
        () => harness.store.ingestCapturedFile(source, processSyncNow: true),
      );

      final asset = harness.store.assets.single;
      await tester.runAsync(
        () => harness.database.updateAssetCloudMetadata(
          assetId: asset.id,
          remoteAssetId: 'remote-gallery-lifecycle',
          uploadPath: 'Joblens/Inbox/gallery-lifecycle.jpg',
          cloudState: AssetCloudState.localAndCloud,
        ),
      );
      await tester.runAsync(harness.store.refresh);

      await tester.pumpWidget(
        _wrapWithStore(harness.store, const GalleryPage()),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);

      await tester.runAsync(
        () => harness.database.updateAssetLocalMedia(
          assetId: asset.id,
          localPath: '',
          thumbPath: '',
          hash: asset.hash,
          cloudState: AssetCloudState.cloudOnly,
        ),
      );
      await tester.runAsync(harness.store.refresh);
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(
        find.text(
          'No photos on this device yet. Capture with Joblens or import from your phone gallery.',
        ),
        findsOneWidget,
      );

      final downloadedOriginal = File(
        p.join(harness.tempDir.path, 'gallery-downloaded.jpg'),
      );
      final downloadedThumb = File(
        p.join(harness.tempDir.path, 'gallery-downloaded-thumb.jpg'),
      );
      await tester.runAsync(
        () => downloadedOriginal.writeAsBytes(List<int>.filled(128, 12)),
      );
      await tester.runAsync(
        () => downloadedThumb.writeAsBytes(List<int>.filled(64, 13)),
      );
      await tester.runAsync(
        () => harness.database.updateAssetLocalMedia(
          assetId: asset.id,
          localPath: downloadedOriginal.path,
          thumbPath: downloadedThumb.path,
          hash: asset.hash,
          cloudState: AssetCloudState.localAndCloud,
        ),
      );
      await tester.runAsync(harness.store.refresh);
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.text(
          'No photos on this device yet. Capture with Joblens or import from your phone gallery.',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'ProjectDetailPage shows project and selection download actions',
    (tester) async {
      final harness = (await tester.runAsync(_createHarness))!;
      addTearDown(harness.dispose);

      await tester.runAsync(
        () => harness.store.createProject('Download Project'),
      );
      final project = harness.store.projects.firstWhere(
        (item) => item.name == 'Download Project',
      );

      final source = File(p.join(harness.tempDir.path, 'project-download.jpg'));
      await tester.runAsync(
        () => source.writeAsBytes(List<int>.filled(128, 5)),
      );
      await tester.runAsync(
        () => harness.store.ingestCapturedFile(source, projectId: project.id),
      );

      final latestProject = harness.store.projects.firstWhere(
        (item) => item.id == project.id,
      );
      await tester.pumpWidget(
        _wrapWithStore(
          harness.store,
          ProjectDetailPage(project: latestProject),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Archive project photos'), findsOneWidget);
      expect(find.byTooltip('Download missing photos'), findsOneWidget);

      await tester.tap(find.byTooltip('Select photos'));
      await tester.pump();
      await tester.tap(find.byType(Image).first);
      await tester.pump();

      expect(find.byTooltip('Archive selected'), findsOneWidget);
      expect(find.byTooltip('Download selected'), findsOneWidget);
    },
  );
}

Widget _wrapWithStore(JoblensStore store, Widget child) {
  return ProviderScope(
    overrides: [joblensStoreProvider.overrideWithValue(store)],
    child: MaterialApp(home: child),
  );
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  int maxTicks = 20,
}) async {
  for (var i = 0; i < maxTicks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (await condition()) {
      return;
    }
  }
}

void _pressIconButton(WidgetTester tester, Finder finder) {
  final buttonFinder = find.ancestor(
    of: finder.first,
    matching: find.byType(IconButton),
  );
  final button = tester.widget<IconButton>(buttonFinder.first);
  final onPressed = button.onPressed;
  expect(onPressed, isNotNull);
  onPressed!();
}

Future<_StoreHarness> _createHarness() async {
  final tempDir = await Directory.systemTemp.createTemp('joblens_widget_test_');
  final dbPath = p.join(tempDir.path, 'joblens.db');
  final database = await AppDatabase.open(databasePath: dbPath);
  final mediaStorage = await MediaStorageService.create(rootDirectory: tempDir);
  final syncService = _NoopSyncService(database);
  final store = JoblensStore(
    database: database,
    mediaStorage: mediaStorage,
    syncService: syncService,
  );
  await store.initialize();
  return _StoreHarness(
    store: store,
    database: database,
    tempDir: tempDir,
    syncService: syncService,
  );
}

class _StoreHarness {
  _StoreHarness({
    required this.store,
    required this.database,
    required this.tempDir,
    required this.syncService,
  });

  final JoblensStore store;
  final AppDatabase database;
  final Directory tempDir;
  final _NoopSyncService syncService;

  Future<void> dispose() async {
    await store.waitForIdle().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    store.dispose();
    await database.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  final Map<String, Uint8List> thumbnailBytesByRemoteAssetId =
      <String, Uint8List>{};
  final List<String> thumbnailRequests = <String>[];

  @override
  Future<void> enqueueAsset(PhotoAsset asset) async {}

  @override
  Future<Uint8List> downloadThumbnailBytes(PhotoAsset asset) async {
    final remoteAssetId = asset.remoteAssetId?.trim() ?? '';
    thumbnailRequests.add(remoteAssetId);
    final bytes = thumbnailBytesByRemoteAssetId[remoteAssetId];
    if (bytes == null) {
      throw StateError('No thumbnail bytes configured for $remoteAssetId.');
    }
    return bytes;
  }

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}

final Uint8List _thumbnailBytes = Uint8List.fromList(
  img.encodeJpg(img.Image(width: 12, height: 12)),
);
