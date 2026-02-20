import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/cloud_provider.dart';
import '../../models/photo_asset.dart';
import '../../models/project.dart';
import '../cloud_adapter.dart';

class NextcloudAdapter implements CloudAdapter {
  NextcloudAdapter({
    required String serverUrl,
    required String username,
    required String appPassword,
  }) : _serverUrl = serverUrl.trim().replaceAll(RegExp(r'/$'), ''),
       _username = username.trim(),
       _appPassword = appPassword;

  final String _serverUrl;
  final String _username;
  final String _appPassword;

  @override
  CloudProviderType get provider => CloudProviderType.nextcloud;

  @override
  Future<void> authenticate() async {
    final uri = _davUri();
    final request = http.Request('PROPFIND', uri)
      ..headers.addAll({
        HttpHeaders.authorizationHeader: _basicAuth,
        'Depth': '0',
      });

    final response = await request.send();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }

    throw CloudSyncException(
      'Nextcloud auth check failed: HTTP ${response.statusCode}',
    );
  }

  @override
  Future<String> ensureProjectFolder(Project project) async {
    await _ensureCollection(['Joblens']);
    final folderName = _safeSegment(project.name);
    await _ensureCollection(['Joblens', folderName]);
    return folderName;
  }

  @override
  Future<void> uploadFile({
    required PhotoAsset asset,
    required Project project,
  }) async {
    final folder = await ensureProjectFolder(project);
    final file = File(asset.localPath);
    if (!file.existsSync()) {
      throw CloudSyncException(
        'Nextcloud upload: missing file ${asset.localPath}',
      );
    }

    final fileName = _safeSegment(file.uri.pathSegments.last);
    final uri = _davUri(pathSegments: ['Joblens', folder, fileName]);

    final response = await http.put(
      uri,
      headers: {
        HttpHeaders.authorizationHeader: _basicAuth,
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
      },
      body: await file.readAsBytes(),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudSyncException(
        'Nextcloud upload failed: HTTP ${response.statusCode} ${response.body.trim()}',
      );
    }
  }

  Future<void> _ensureCollection(List<String> segments) async {
    final uri = _davUri(pathSegments: segments);
    final response = http.Request('MKCOL', uri)
      ..headers[HttpHeaders.authorizationHeader] = _basicAuth;

    final streamed = await response.send();
    // 201 created, 405 already exists.
    if (streamed.statusCode == 201 || streamed.statusCode == 405) {
      return;
    }

    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return;
    }

    final body = await streamed.stream.bytesToString();
    throw CloudSyncException(
      'Nextcloud MKCOL failed: HTTP ${streamed.statusCode} ${body.trim()}',
    );
  }

  Uri _davUri({List<String> pathSegments = const []}) {
    final base = [
      'remote.php',
      'dav',
      'files',
      _username,
      ...pathSegments,
    ].map(Uri.encodeComponent).join('/');

    return Uri.parse('$_serverUrl/$base');
  }

  String get _basicAuth {
    final token = base64Encode(utf8.encode('$_username:$_appPassword'));
    return 'Basic $token';
  }

  String _safeSegment(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return 'Untitled';
    }
    return trimmed.replaceAll('/', '_');
  }
}
