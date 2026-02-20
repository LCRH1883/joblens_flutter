import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/cloud_provider.dart';
import '../../models/photo_asset.dart';
import '../../models/project.dart';
import '../cloud_adapter.dart';
import 'http_support.dart';

class GoogleDriveAdapter implements CloudAdapter {
  GoogleDriveAdapter({required String accessToken})
    : _accessToken = accessToken.trim();

  final String _accessToken;
  String? _joblensRootId;

  static const _folderMime = 'application/vnd.google-apps.folder';

  @override
  CloudProviderType get provider => CloudProviderType.googleDrive;

  @override
  Future<void> authenticate() async {
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/about?fields=user',
    );
    final response = await http.get(uri, headers: _headers);
    response.ensureSuccess(context: 'Google Drive auth check');
  }

  @override
  Future<String> ensureProjectFolder(Project project) async {
    final rootId = await _ensureJoblensRoot();
    return _ensureFolder(project.name, parentId: rootId);
  }

  @override
  Future<void> uploadFile({
    required PhotoAsset asset,
    required Project project,
  }) async {
    final projectFolderId = await ensureProjectFolder(project);
    final sourceFile = File(asset.localPath);
    if (!sourceFile.existsSync()) {
      throw CloudSyncException(
        'Google Drive upload: missing file ${asset.localPath}',
      );
    }

    final fileName = _safeFileName(sourceFile.uri.pathSegments.last);

    // 1) Create metadata record.
    final createUri = Uri.parse('https://www.googleapis.com/drive/v3/files');
    final createResponse = await http.post(
      createUri,
      headers: _headers,
      body: jsonEncode({
        'name': fileName,
        'parents': [projectFolderId],
      }),
    );

    final created = createResponse.decodeJsonMap(
      context: 'Google Drive create file',
    );
    final fileId = created['id'] as String?;
    if (fileId == null || fileId.isEmpty) {
      throw const CloudSyncException(
        'Google Drive create file returned no file ID',
      );
    }

    // 2) Upload bytes to the created file.
    final uploadUri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media',
    );

    final uploadResponse = await http.patch(
      uploadUri,
      headers: {
        ..._headers,
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
      },
      body: await sourceFile.readAsBytes(),
    );
    uploadResponse.ensureSuccess(context: 'Google Drive upload bytes');
  }

  Future<String> _ensureJoblensRoot() async {
    final cached = _joblensRootId;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final root = await _ensureFolder('Joblens', parentId: 'root');
    _joblensRootId = root;
    return root;
  }

  Future<String> _ensureFolder(
    String folderName, {
    required String parentId,
  }) async {
    final escaped = folderName.replaceAll("'", "\\'");
    final query =
        "name = '$escaped' and mimeType = '$_folderMime' and trashed = false and '$parentId' in parents";

    final listUri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files?'
      'q=${Uri.encodeQueryComponent(query)}&'
      'spaces=drive&fields=files(id,name)&pageSize=10',
    );

    final listResponse = await http.get(listUri, headers: _headers);
    final listed = listResponse.decodeJsonMap(
      context: 'Google Drive list folder',
    );
    final files = (listed['files'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (files.isNotEmpty) {
      final id = files.first['id'] as String?;
      if (id != null && id.isNotEmpty) {
        return id;
      }
    }

    final createUri = Uri.parse('https://www.googleapis.com/drive/v3/files');
    final createResponse = await http.post(
      createUri,
      headers: _headers,
      body: jsonEncode({
        'name': folderName,
        'mimeType': _folderMime,
        'parents': [parentId],
      }),
    );

    final created = createResponse.decodeJsonMap(
      context: 'Google Drive create folder',
    );
    final id = created['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const CloudSyncException(
        'Google Drive create folder returned no folder ID',
      );
    }

    return id;
  }

  Map<String, String> get _headers => {
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
