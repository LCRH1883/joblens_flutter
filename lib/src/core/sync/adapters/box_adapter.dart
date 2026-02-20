import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/cloud_provider.dart';
import '../../models/photo_asset.dart';
import '../../models/project.dart';
import '../cloud_adapter.dart';
import 'http_support.dart';

class BoxAdapter implements CloudAdapter {
  BoxAdapter({required String accessToken}) : _accessToken = accessToken.trim();

  final String _accessToken;
  String? _joblensRootId;

  @override
  CloudProviderType get provider => CloudProviderType.box;

  @override
  Future<void> authenticate() async {
    final uri = Uri.parse('https://api.box.com/2.0/users/me');
    final response = await http.get(uri, headers: _jsonHeaders);
    response.ensureSuccess(context: 'Box auth check');
  }

  @override
  Future<String> ensureProjectFolder(Project project) async {
    final rootId = await _ensureJoblensRoot();
    return _ensureFolder(name: project.name, parentId: rootId);
  }

  @override
  Future<void> uploadFile({
    required PhotoAsset asset,
    required Project project,
  }) async {
    final folderId = await ensureProjectFolder(project);
    final file = File(asset.localPath);
    if (!file.existsSync()) {
      throw CloudSyncException('Box upload: missing file ${asset.localPath}');
    }

    final fileName = _safeFileName(file.uri.pathSegments.last);
    final existingId = await _findFileId(
      parentId: folderId,
      fileName: fileName,
    );
    if (existingId != null) {
      return;
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://upload.box.com/api/2.0/files/content'),
    );

    request.headers[HttpHeaders.authorizationHeader] = 'Bearer $_accessToken';
    request.fields['attributes'] = jsonEncode({
      'name': fileName,
      'parent': {'id': folderId},
    });
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    final response = await request.send();
    await ensureMultipartSuccess(response, context: 'Box upload file');
  }

  Future<String> _ensureJoblensRoot() async {
    final cached = _joblensRootId;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final root = await _ensureFolder(name: 'Joblens', parentId: '0');
    _joblensRootId = root;
    return root;
  }

  Future<String> _ensureFolder({
    required String name,
    required String parentId,
  }) async {
    final existing = await _findFolderId(parentId: parentId, folderName: name);
    if (existing != null) {
      return existing;
    }

    final createUri = Uri.parse('https://api.box.com/2.0/folders');
    final response = await http.post(
      createUri,
      headers: _jsonHeaders,
      body: jsonEncode({
        'name': name,
        'parent': {'id': parentId},
      }),
    );

    if (response.statusCode == 409) {
      final conflict = await _findFolderId(
        parentId: parentId,
        folderName: name,
      );
      if (conflict != null) {
        return conflict;
      }
    }

    final decoded = response.decodeJsonMap(context: 'Box create folder');
    final id = decoded['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const CloudSyncException('Box create folder returned no folder ID');
    }

    return id;
  }

  Future<String?> _findFolderId({
    required String parentId,
    required String folderName,
  }) async {
    final items = await _listFolderItems(parentId);
    for (final item in items) {
      final type = item['type'] as String?;
      final name = item['name'] as String?;
      if (type == 'folder' && name == folderName) {
        return item['id'] as String?;
      }
    }
    return null;
  }

  Future<String?> _findFileId({
    required String parentId,
    required String fileName,
  }) async {
    final items = await _listFolderItems(parentId);
    for (final item in items) {
      final type = item['type'] as String?;
      final name = item['name'] as String?;
      if (type == 'file' && name == fileName) {
        return item['id'] as String?;
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _listFolderItems(String parentId) async {
    final uri = Uri.parse(
      'https://api.box.com/2.0/folders/$parentId/items?limit=1000&fields=id,name,type',
    );
    final response = await http.get(uri, headers: _jsonHeaders);
    final decoded = response.decodeJsonMap(context: 'Box list items');
    final entries = decoded['entries'] as List<dynamic>? ?? <dynamic>[];
    return entries.whereType<Map<String, dynamic>>().toList();
  }

  Map<String, String> get _jsonHeaders => {
    HttpHeaders.authorizationHeader: 'Bearer $_accessToken',
    HttpHeaders.acceptHeader: 'application/json',
    HttpHeaders.contentTypeHeader: 'application/json',
  };

  String _safeFileName(String original) {
    final trimmed = original.trim();
    if (trimmed.isEmpty) {
      return 'photo.jpg';
    }
    return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
