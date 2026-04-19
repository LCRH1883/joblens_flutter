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

  String createAssetId() => _uuid.v4();

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
    final id = createAssetId();
    final stored = await ingestIntoStorage(assetId: id, source: source);
    final now = DateTime.now();
    return PhotoAsset(
      id: id,
      localPath: stored.localPath,
      thumbPath: stored.thumbPath,
      createdAt: createdAt ?? now,
      importedAt: now,
      projectId: projectId,
      hash: stored.hash,
      status: AssetStatus.active,
      sourceType: sourceType,
      cloudState: AssetCloudState.localAndCloud,
      existsInPhoneStorage: false,
    );
  }

  Future<({String localPath, String thumbPath, String hash})>
  ingestIntoStorage({required String assetId, required File source}) async {
    final extension = p.extension(source.path).isEmpty
        ? '.jpg'
        : p.extension(source.path);
    final storedPath = p.join(originalsDir.path, '$assetId$extension');
    final generatedThumbPath = p.join(thumbnailsDir.path, '$assetId.jpg');

    await source.copy(storedPath);
    final result = await Isolate.run(
      () => _generateHashAndThumbnail(storedPath, generatedThumbPath),
    );
    final thumbPath = result.generatedThumbnail
        ? generatedThumbPath
        : storedPath;
    return (localPath: storedPath, thumbPath: thumbPath, hash: result.hash);
  }

  Future<({String localPath, String thumbPath, String hash})>
  storeDownloadedBytes({
    required String assetId,
    required Uint8List bytes,
    String? filename,
  }) async {
    final safeAssetId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final extension = p.extension(filename ?? '').isEmpty
        ? '.jpg'
        : p.extension(filename!);
    final storedPath = p.join(originalsDir.path, '$safeAssetId$extension');
    final generatedThumbPath = p.join(thumbnailsDir.path, '$safeAssetId.jpg');

    await File(storedPath).writeAsBytes(bytes, flush: true);
    final result = await Isolate.run(
      () => _generateHashAndThumbnail(storedPath, generatedThumbPath),
    );
    final thumbPath = result.generatedThumbnail
        ? generatedThumbPath
        : storedPath;

    return (localPath: storedPath, thumbPath: thumbPath, hash: result.hash);
  }

  Future<String> storeThumbnailBytes({
    required String assetId,
    required Uint8List bytes,
  }) async {
    final safeAssetId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final storedThumbPath = p.join(thumbnailsDir.path, '$safeAssetId.jpg');
    final result = await Isolate.run(
      () => _storeNormalizedThumbnail(bytes, storedThumbPath),
    );
    if (!result.generatedThumbnail) {
      throw StateError('Failed to persist a normalized thumbnail.');
    }
    return storedThumbPath;
  }

  Future<String> ensureStandaloneThumbnail({
    required String assetId,
    required String localPath,
    required String thumbPath,
  }) async {
    final originalPath = localPath.trim();
    if (originalPath.isEmpty) {
      throw StateError('Cannot preserve a thumbnail without a local original.');
    }

    final originalFile = File(originalPath);
    if (!await originalFile.exists()) {
      throw StateError(
        'Cannot preserve a thumbnail because the local original is missing.',
      );
    }

    final existingThumbPath = thumbPath.trim();
    if (existingThumbPath.isNotEmpty && existingThumbPath != originalPath) {
      final existingThumbFile = File(existingThumbPath);
      if (await existingThumbFile.exists()) {
        return existingThumbPath;
      }
    }

    final safeAssetId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final preservedThumbPath = p.join(thumbnailsDir.path, '$safeAssetId.jpg');
    final result = await Isolate.run(
      () => _generateStandaloneThumbnail(originalPath, preservedThumbPath),
    );
    if (!result.generatedThumbnail) {
      throw StateError(
        'Failed to generate a standalone thumbnail for the local original.',
      );
    }
    return preservedThumbPath;
  }

  Future<void> clearAll() async {
    await rootDir.create(recursive: true);
    for (var attempt = 0; attempt < 3; attempt++) {
      await _clearDirectoryContents(rootDir);
      if (!await _hasDirectoryEntries(rootDir)) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    await rootDir.create(recursive: true);
    await originalsDir.create(recursive: true);
    await thumbnailsDir.create(recursive: true);
  }

  Future<void> _clearDirectoryContents(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return;
      }
      await for (final entity in directory.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } on PathNotFoundException {
          // Concurrent cleanup or in-flight file writes may have already removed
          // the entry. Clearing storage is best-effort during sign-out.
        } on FileSystemException {
          // iOS can report "Directory not empty" when a concurrent write races
          // with recursive deletion. A follow-up pass will retry cleanup.
        }
      }
    } on PathNotFoundException {
      // The directory disappeared between the existence check and listing.
    }
  }

  Future<bool> _hasDirectoryEntries(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return false;
      }
      await for (final _ in directory.list(followLinks: false)) {
        return true;
      }
      return false;
    } on PathNotFoundException {
      return false;
    }
  }
}

({String hash, bool generatedThumbnail}) _generateHashAndThumbnail(
  String sourcePath,
  String thumbPath,
) {
  final sourceBytes = File(sourcePath).readAsBytesSync();
  final hash = sha256.convert(sourceBytes).toString();

  final decoded = img.decodeImage(Uint8List.fromList(sourceBytes));
  if (decoded == null) {
    return (hash: hash, generatedThumbnail: false);
  }

  final resized = img.copyResize(decoded, width: 512);
  final encoded = img.encodeJpg(resized, quality: 85);
  File(thumbPath).writeAsBytesSync(encoded, flush: true);
  return (hash: hash, generatedThumbnail: true);
}

({bool generatedThumbnail}) _generateStandaloneThumbnail(
  String sourcePath,
  String thumbPath,
) {
  final sourceBytes = File(sourcePath).readAsBytesSync();
  final decoded = img.decodeImage(Uint8List.fromList(sourceBytes));
  if (decoded == null) {
    return (generatedThumbnail: false);
  }

  final resized = img.copyResize(decoded, width: 512);
  final encoded = img.encodeJpg(resized, quality: 85);
  File(thumbPath).writeAsBytesSync(encoded, flush: true);
  return (generatedThumbnail: true);
}

({bool generatedThumbnail}) _storeNormalizedThumbnail(
  Uint8List bytes,
  String thumbPath,
) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return (generatedThumbnail: false);
  }

  final resized = img.copyResize(decoded, width: 512);
  final encoded = img.encodeJpg(resized, quality: 85);
  File(thumbPath).writeAsBytesSync(encoded, flush: true);
  return (generatedThumbnail: true);
}
