import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/cloud_provider.dart';
import '../../models/photo_asset.dart';
import '../../models/project.dart';
import '../cloud_adapter.dart';
import 'http_support.dart';

class OneDriveAdapter implements CloudAdapter {
  OneDriveAdapter({required String accessToken})
    : _accessToken = accessToken.trim();

  final String _accessToken;

  @override
  CloudProviderType get provider => CloudProviderType.oneDrive;

  @override
  Future<void> authenticate() async {
    final uri = Uri.parse('https://graph.microsoft.com/v1.0/me/drive');
    final response = await http.get(uri, headers: _jsonHeaders);
    response.ensureSuccess(context: 'OneDrive auth check');
  }

  @override
  Future<String> ensureProjectFolder(Project project) async {
    await _ensureFolder('Joblens', parentItemId: 'root');
    final normalized = _normalize(project.name);
    await _ensurePathExists('Joblens/$normalized');
    return normalized;
  }

  @override
  Future<void> uploadFile({
    required PhotoAsset asset,
    required Project project,
  }) async {
    final projectFolderName = await ensureProjectFolder(project);
    final source = File(asset.localPath);
    if (!source.existsSync()) {
      throw CloudSyncException(
        'OneDrive upload: missing file ${asset.localPath}',
      );
    }

    final fileName = _normalize(source.uri.pathSegments.last);
    final encodedProject = Uri.encodeComponent(projectFolderName);
    final encodedFile = Uri.encodeComponent(fileName);
    final path =
        '/me/drive/root:/Joblens/$encodedProject/$encodedFile:/content';
    final uri = Uri.parse('https://graph.microsoft.com/v1.0$path');

    final response = await http.put(
      uri,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $_accessToken',
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
      },
      body: await source.readAsBytes(),
    );

    response.ensureSuccess(context: 'OneDrive upload file');
  }

  Future<void> _ensurePathExists(String path) async {
    final segments = path.split('/').where((segment) => segment.isNotEmpty);
    var currentPath = '';
    String parent = 'root';

    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final encodedPath = currentPath
          .split('/')
          .map(Uri.encodeComponent)
          .join('/');
      final checkUri = Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/root:/$encodedPath',
      );

      final checkResponse = await http.get(checkUri, headers: _jsonHeaders);
      if (checkResponse.statusCode >= 200 && checkResponse.statusCode < 300) {
        final decoded = jsonDecode(checkResponse.body) as Map<String, dynamic>;
        parent = decoded['id'] as String? ?? parent;
        continue;
      }

      await _ensureFolder(segment, parentItemId: parent);

      final createdCheck = await http.get(checkUri, headers: _jsonHeaders);
      final decoded = createdCheck.decodeJsonMap(
        context: 'OneDrive read created folder',
      );
      parent = decoded['id'] as String? ?? parent;
    }
  }

  Future<void> _ensureFolder(
    String name, {
    required String parentItemId,
  }) async {
    final endpoint = parentItemId == 'root'
        ? 'https://graph.microsoft.com/v1.0/me/drive/root/children'
        : 'https://graph.microsoft.com/v1.0/me/drive/items/$parentItemId/children';

    final createResponse = await http.post(
      Uri.parse(endpoint),
      headers: _jsonHeaders,
      body: jsonEncode({
        'name': name,
        'folder': <String, dynamic>{},
        '@microsoft.graph.conflictBehavior': 'fail',
      }),
    );

    // 201 = created, 409 = already exists.
    if (createResponse.statusCode == 201 || createResponse.statusCode == 409) {
      return;
    }

    createResponse.ensureSuccess(context: 'OneDrive ensure folder');
  }

  Map<String, String> get _jsonHeaders => {
    HttpHeaders.authorizationHeader: 'Bearer $_accessToken',
    HttpHeaders.acceptHeader: 'application/json',
    HttpHeaders.contentTypeHeader: 'application/json',
  };

  String _normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Untitled';
    }

    return trimmed.replaceAll(RegExp(r'["*:<>?/\\|]'), '_');
  }
}
