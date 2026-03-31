import 'package:flutter_test/flutter_test.dart';
import 'package:joblens_flutter/src/core/db/app_database.dart';

void main() {
  group('rebaseMediaPath', () {
    test('rewrites iOS sandbox media paths to the current media root', () {
      const original =
          '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/joblens_media/originals/asset.jpg';
      const currentRoot =
          '/var/mobile/Containers/Data/Application/NEW-UUID/Documents/joblens_media';

      final rebased = rebaseMediaPath(original, currentRoot);

      expect(
        rebased,
        '/var/mobile/Containers/Data/Application/NEW-UUID/Documents/joblens_media/originals/asset.jpg',
      );
    });

    test('leaves unrelated paths unchanged', () {
      const original = '/tmp/random/file.jpg';
      const currentRoot =
          '/var/mobile/Containers/Data/Application/NEW-UUID/Documents/joblens_media';

      expect(rebaseMediaPath(original, currentRoot), original);
    });
  });
}
