import 'dart:io';
import 'dart:isolate';
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

  static Future<MediaStorageService> create({Directory? rootDirectory}) async {
    final root = rootDirectory != null
        ? Directory(p.join(rootDirectory.path, 'joblens_media'))
        : Directory(
            p.join(
              (await getApplicationDocumentsDirectory()).path,
              'joblens_media',
            ),
          );
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

    await source.copy(storedPath);
    final hash = await Isolate.run(
      () => _generateHashAndThumbnail(storedPath, thumbPath),
    );

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
      cloudState: AssetCloudState.localAndCloud,
      remoteAssetId: null,
      remoteProvider: null,
      remoteFileId: null,
      uploadSessionId: null,
      uploadPath: null,
      lastSyncErrorCode: null,
    );
  }

  Future<void> clearAll() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }

    await rootDir.create(recursive: true);
    await originalsDir.create(recursive: true);
    await thumbnailsDir.create(recursive: true);
  }
}

String _generateHashAndThumbnail(String sourcePath, String thumbPath) {
  final sourceBytes = File(sourcePath).readAsBytesSync();
  final hash = sha256.convert(sourceBytes).toString();

  final decoded = img.decodeImage(Uint8List.fromList(sourceBytes));
  if (decoded == null) {
    File(thumbPath).writeAsBytesSync(sourceBytes, flush: true);
    return hash;
  }

  final resized = img.copyResize(decoded, width: 512);
  final encoded = img.encodeJpg(resized, quality: 85);
  File(thumbPath).writeAsBytesSync(encoded, flush: true);
  return hash;
}
