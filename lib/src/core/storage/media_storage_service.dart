import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/photo_asset.dart';

class MediaStorageService {
  MediaStorageService._({
    required this.rootDir,
    required this.originalsDir,
    required this.thumbnailsDir,
  });

  final Directory rootDir;
  final Directory originalsDir;
  final Directory thumbnailsDir;
  static const _uuid = Uuid();

  static Future<MediaStorageService> create() async {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(documents.path, 'joblens_media'));
    final originals = Directory(p.join(root.path, 'originals'));
    final thumbs = Directory(p.join(root.path, 'thumbnails'));

    await root.create(recursive: true);
    await originals.create(recursive: true);
    await thumbs.create(recursive: true);

    return MediaStorageService._(
      rootDir: root,
      originalsDir: originals,
      thumbnailsDir: thumbs,
    );
  }

  Future<PhotoAsset> ingestFile({
    required File source,
    required AssetSourceType sourceType,
    required int projectId,
    DateTime? createdAt,
  }) async {
    final id = _uuid.v4();
    final extension = p.extension(source.path).isEmpty
        ? '.jpg'
        : p.extension(source.path);
    final storedPath = p.join(originalsDir.path, '$id$extension');
    final thumbPath = p.join(thumbnailsDir.path, '$id.jpg');

    final copied = await source.copy(storedPath);
    final bytes = await copied.readAsBytes();
    final hash = sha256.convert(bytes).toString();

    await _createThumbnail(bytes: bytes, outputPath: thumbPath);

    final now = DateTime.now();
    return PhotoAsset(
      id: id,
      localPath: storedPath,
      thumbPath: thumbPath,
      createdAt: createdAt ?? now,
      importedAt: now,
      projectId: projectId,
      hash: hash,
      status: AssetStatus.active,
      sourceType: sourceType,
    );
  }

  Future<void> _createThumbnail({
    required List<int> bytes,
    required String outputPath,
  }) async {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      await File(outputPath).writeAsBytes(bytes, flush: true);
      return;
    }

    final resized = img.copyResize(decoded, width: 512);
    final encoded = img.encodeJpg(resized, quality: 85);
    await File(outputPath).writeAsBytes(encoded, flush: true);
  }
}
