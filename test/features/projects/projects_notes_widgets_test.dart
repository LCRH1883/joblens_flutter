import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/app/joblens_store.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/core/models/photo_asset.dart';
import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';
import 'package:joblens_flutter/src/core/sync/sync_service.dart';
import 'package:joblens_flutter/src/features/gallery/gallery_page.dart';
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
  final store = JoblensStore(
    database: database,
    mediaStorage: mediaStorage,
    syncService: _NoopSyncService(database),
  );
  await store.initialize();
  return _StoreHarness(store: store, database: database, tempDir: tempDir);
}

class _StoreHarness {
  _StoreHarness({
    required this.store,
    required this.database,
    required this.tempDir,
  });

  final JoblensStore store;
  final AppDatabase database;
  final Directory tempDir;

  Future<void> dispose() async {
    await store.waitForIdle();
    store.dispose();
    await database.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}

class _NoopSyncService extends SyncService {
  _NoopSyncService(super.db) : super();

  @override
  Future<void> enqueueAsset(PhotoAsset asset) async {}

  @override
  Future<void> kick({bool forceBootstrap = false}) async {}
}
