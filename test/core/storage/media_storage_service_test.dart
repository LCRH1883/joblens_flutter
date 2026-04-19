import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:joblens_flutter/src/core/storage/media_storage_service.dart';

void main() {
  test(
    'storeThumbnailBytes writes normalized thumbnails to a deterministic path',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_media_storage_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final storage = await MediaStorageService.create(rootDirectory: tempDir);
      final firstBytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 16, height: 16)),
      );
      final secondBytes = Uint8List.fromList(
        img.encodePng(
          img.fill(
            img.Image(width: 24, height: 24),
            color: img.ColorRgb8(12, 34, 56),
          ),
        ),
      );

      final firstPath = await storage.storeThumbnailBytes(
        assetId: 'asset-1',
        bytes: firstBytes,
      );
      final secondPath = await storage.storeThumbnailBytes(
        assetId: 'asset-1',
        bytes: secondBytes,
      );

      expect(firstPath, endsWith('/joblens_media/thumbnails/asset-1.jpg'));
      expect(secondPath, firstPath);

      final storedFile = File(firstPath);
      expect(storedFile.existsSync(), isTrue);
      final storedBytes = await storedFile.readAsBytes();
      expect(img.decodeJpg(storedBytes), isNotNull);
    },
  );

  test(
    'clearAll tolerates missing or concurrent storage directories',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'joblens_media_storage_clear_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final storage = await MediaStorageService.create(rootDirectory: tempDir);
      await storage.storeThumbnailBytes(
        assetId: 'asset-1',
        bytes: Uint8List.fromList(
          img.encodePng(img.Image(width: 8, height: 8)),
        ),
      );

      await storage.rootDir.delete(recursive: true);

      await Future.wait([storage.clearAll(), storage.clearAll()]);

      expect(await storage.rootDir.exists(), isTrue);
      expect(await storage.originalsDir.exists(), isTrue);
      expect(await storage.thumbnailsDir.exists(), isTrue);
    },
  );
}
