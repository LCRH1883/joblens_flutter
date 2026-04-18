import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/db/app_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('ensureDefaultProject is safe when called concurrently', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'joblens_db_default_project_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    addTearDown(database.close);

    final results = await Future.wait(
      List.generate(12, (_) => database.ensureDefaultProject()),
    );

    expect(results.toSet(), hasLength(1));

    final projects = await database.getProjects();
    expect(projects, hasLength(1));
    expect(projects.single.name, 'Inbox');
  });
}
