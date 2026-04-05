import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/cloud_provider.dart';
import 'api_exception.dart';
import 'backend_api_models.dart';
import 'backend_auth.dart';

class JoblensBackendApiClient {
  JoblensBackendApiClient({
    required String baseUrl,
    required AccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client();

  final String _baseUrl;
  final AccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;

  Future<ProviderConnectionsResponse> listProviderConnections() async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/providers/connections',
    );
    return ProviderConnectionsResponse.fromMap(map);
  }

  Future<BeginProviderConnectionResponse> beginProviderConnection(
    CloudProviderType provider,
  ) async {
    final callbackUri = Uri.parse(
      '$_baseUrl/providers/${provider.key}/oauth/callback',
    ).toString();
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/providers/${provider.key}/connect',
      body: {
        'redirectUri': callbackUri,
        'redirectTo': 'joblens://auth-callback',
      },
    );
    return BeginProviderConnectionResponse.fromMap(map);
  }

  Future<void> connectNextcloud(NextcloudConnectionRequest request) async {
    await _authorizedJsonRequest(
      method: 'POST',
      path: '/providers/nextcloud/connect',
      body: request.toMap(),
    );
  }

  Future<void> disconnectProvider(CloudProviderType provider) async {
    await _authorizedJsonRequest(
      method: 'POST',
      path: '/providers/${provider.key}/disconnect',
    );
  }

  Future<void> deleteAccount() async {
    await _authorizedJsonRequest(
      method: 'POST',
      path: '/account/delete',
    );
  }

  Future<RemoteProjectRecord> upsertProject(
    RemoteProjectUpsertRequest request,
  ) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/projects/upsert',
      body: request.toMap(),
    );
    return RemoteProjectRecord.fromMap(
      map['project'] is Map<String, dynamic>
          ? map['project'] as Map<String, dynamic>
          : map,
    );
  }

  Future<ListProjectsResponse> listProjects() async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/projects',
    );
    return ListProjectsResponse.fromMap(map);
  }

  Future<void> archiveProject(String remoteProjectId) async {
    await _authorizedJsonRequest(
      method: 'POST',
      path: '/projects/$remoteProjectId/archive',
    );
  }

  Future<BulkCheckAssetsResponse> bulkCheckAssets({
    required String projectId,
    required List<BulkCheckAssetInput> assets,
  }) async {
    final body = {
      'projectId': projectId,
      'assets': assets.map((item) => item.toMap()).toList(growable: false),
    };
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/bulk-check',
      body: body,
    );
    return BulkCheckAssetsResponse.fromMap(map);
  }

  Future<PrepareAssetUploadResponse> prepareAssetUpload(
    PrepareAssetUploadRequest request,
  ) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/prepare-upload',
      body: request.toMap(),
    );
    return PrepareAssetUploadResponse.fromMap(map);
  }

  Future<CommitAssetResponse> commitAsset(CommitAssetRequest request) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/commit',
      body: request.toMap(),
    );
    return CommitAssetResponse.fromMap(map);
  }

  Future<MoveAssetResponse> moveAssetToProject({
    required String assetId,
    required String projectId,
  }) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/$assetId/move',
      body: {'projectId': projectId},
    );
    return MoveAssetResponse.fromMap(map);
  }

  Future<void> deleteAsset(String assetId) async {
    await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/$assetId/delete',
    );
  }

  Future<ListAssetsResponse> listAssets(ListAssetsRequest request) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets',
      query: request.toQuery(),
    );
    return ListAssetsResponse.fromMap(map);
  }

  Future<SignedMediaUrlResponse> getThumbnailUrl(String assetId) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets/$assetId/thumbnail-url',
    );
    return _normalizeSignedMediaUrlResponse(SignedMediaUrlResponse.fromMap(map));
  }

  Future<SignedMediaUrlResponse> getDownloadUrl(String assetId) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets/$assetId/download-url',
    );
    return _normalizeSignedMediaUrlResponse(SignedMediaUrlResponse.fromMap(map));
  }

  Future<Uint8List> downloadAssetBytes(String assetId) async {
    final signed = await getDownloadUrl(assetId);
    final response = await _httpClient.get(Uri.parse(signed.url));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        code: 'remote_download_failed',
        message:
            'Remote asset download failed with HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<SignedMediaUrlResponse> getVideoPreviewUrl(String assetId) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets/$assetId/video-preview-url',
    );
    return _normalizeSignedMediaUrlResponse(SignedMediaUrlResponse.fromMap(map));
  }

  SignedMediaUrlResponse _normalizeSignedMediaUrlResponse(
    SignedMediaUrlResponse response,
  ) {
    return SignedMediaUrlResponse(
      url: _normalizeMediaUrl(response.url),
      ttlSec: response.ttlSec,
    );
  }

  String _normalizeMediaUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final mediaUri = Uri.tryParse(trimmed);
    final baseUri = Uri.tryParse(_baseUrl);
    if (mediaUri == null || baseUri == null) {
      return trimmed;
    }
    if (!mediaUri.hasAuthority) {
      return trimmed;
    }

    final shouldRewriteHost =
        mediaUri.host == 'supabase_edge_runtime_backend' ||
        mediaUri.host == 'localhost' ||
        mediaUri.host == '127.0.0.1';
    final isBackendMediaPath =
        mediaUri.path.startsWith('/functions/v1/api/v1/media/');

    if (!shouldRewriteHost || !isBackendMediaPath) {
      return trimmed;
    }

    return Uri(
      scheme: baseUri.scheme,
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      path: mediaUri.path,
      query: mediaUri.hasQuery ? mediaUri.query : null,
      fragment: mediaUri.hasFragment ? mediaUri.fragment : null,
    ).toString();
  }

  Future<void> uploadWithInstruction({
    required DirectUploadInstruction instruction,
    required Uint8List bytes,
    required String contentType,
    required String filename,
  }) async {
    switch (instruction.strategy) {
      case 'single_put':
        await _sendBinaryRequest(
          method: 'PUT',
          url: instruction.url,
          bytes: bytes,
          contentType: contentType,
          headers: instruction.headers,
        );
      case 'single_post':
        await _sendBinaryRequest(
          method: 'POST',
          url: instruction.url,
          bytes: bytes,
          contentType: contentType,
          headers: instruction.headers,
        );
      case 'multipart_post':
        await _sendMultipartRequest(
          instruction: instruction,
          bytes: bytes,
          filename: filename,
        );
      case 'chunked_put':
        await _sendChunkedPut(
          instruction: instruction,
          bytes: bytes,
          contentType: contentType,
        );
      default:
        throw ApiException(
          code: 'unsupported_upload_strategy',
          message: 'Unsupported upload strategy: ${instruction.strategy}',
        );
    }

    if (instruction.completionUrl != null &&
        instruction.completionUrl!.isNotEmpty) {
      await _sendCompletionRequest(instruction);
    }
  }

  Future<void> _sendBinaryRequest({
    required String method,
    required String url,
    required Uint8List bytes,
    required String contentType,
    required Map<String, String> headers,
  }) async {
    final mergedHeaders = <String, String>{
      ...headers,
      if (!headers.containsKey('Content-Type')) 'Content-Type': contentType,
    };
    final response = switch (method) {
      'PUT' => await _httpClient.put(
        Uri.parse(url),
        headers: mergedHeaders,
        body: bytes,
      ),
      'POST' => await _httpClient.post(
        Uri.parse(url),
        headers: mergedHeaders,
        body: bytes,
      ),
      _ => throw ArgumentError.value(method, 'method', 'Unsupported method'),
    };
    _ensureUploadSucceeded(response);
  }

  Future<void> _sendMultipartRequest({
    required DirectUploadInstruction instruction,
    required Uint8List bytes,
    required String filename,
  }) async {
    final request = http.MultipartRequest(
      instruction.method,
      Uri.parse(instruction.url),
    );
    request.headers.addAll(instruction.headers);
    request.fields.addAll(instruction.fields);
    request.files.add(
      http.MultipartFile.fromBytes(
        instruction.fileFieldName,
        bytes,
        filename: filename,
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    _ensureUploadSucceeded(response);
  }

  Future<void> _sendChunkedPut({
    required DirectUploadInstruction instruction,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final chunkSize =
        instruction.chunkSizeBytes == null || instruction.chunkSizeBytes! <= 0
        ? bytes.length
        : instruction.chunkSizeBytes!;
    var start = 0;
    while (start < bytes.length) {
      final endExclusive = (start + chunkSize > bytes.length)
          ? bytes.length
          : start + chunkSize;
      final chunk = Uint8List.sublistView(bytes, start, endExclusive);
      final headers = <String, String>{
        ...instruction.headers,
        if (!instruction.headers.containsKey('Content-Type'))
          'Content-Type': contentType,
        'Content-Length': '${chunk.length}',
        'Content-Range': 'bytes $start-${endExclusive - 1}/${bytes.length}',
      };
      final response = await _httpClient.put(
        Uri.parse(instruction.url),
        headers: headers,
        body: chunk,
      );
      _ensureUploadSucceeded(response);
      start = endExclusive;
    }
  }

  Future<void> _sendCompletionRequest(
    DirectUploadInstruction instruction,
  ) async {
    final method = (instruction.completionMethod ?? 'POST').toUpperCase();
    final headers = <String, String>{
      'Accept': 'application/json',
      ...?instruction.completionHeaders,
      if (instruction.completionBody != null)
        'Content-Type': 'application/json',
    };
    final uri = Uri.parse(instruction.completionUrl!);
    final body = instruction.completionBody == null
        ? null
        : jsonEncode(instruction.completionBody);
    final response = switch (method) {
      'POST' => await _httpClient.post(uri, headers: headers, body: body),
      'PUT' => await _httpClient.put(uri, headers: headers, body: body),
      _ => throw ArgumentError.value(
        method,
        'completionMethod',
        'Unsupported completion method',
      ),
    };
    _ensureUploadSucceeded(response);
  }

  void _ensureUploadSucceeded(http.Response response) {
    final status = response.statusCode;
    if (status == 200 || status == 201 || status == 202 || status == 204) {
      return;
    }

    throw ApiException(
      code: 'upload_failed',
      message: 'Direct upload failed with HTTP $status.',
      statusCode: status,
      rawBody: response.body,
    );
  }

  Future<Map<String, dynamic>> _authorizedJsonRequest({
    required String method,
    required String path,
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    final firstToken = await _accessTokenProvider.getAccessToken();
    if (firstToken == null || firstToken.trim().isEmpty) {
      throw ApiException.authMissing();
    }

    var response = await _send(
      method: method,
      path: path,
      token: firstToken,
      body: body,
      query: query,
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      final refreshedToken = await _accessTokenProvider.getAccessToken(
        forceRefresh: true,
      );
      if (refreshedToken == null || refreshedToken.trim().isEmpty) {
        throw ApiException.authMissing();
      }
      response = await _send(
        method: method,
        path: path,
        token: refreshedToken,
        body: body,
        query: query,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapApiException(response);
    }

    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }

    throw ApiException(
      code: 'invalid_response',
      message: 'Expected a JSON object response.',
      statusCode: response.statusCode,
      rawBody: response.body,
    );
  }

  Future<http.Response> _send({
    required String method,
    required String path,
    required String token,
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };

    return switch (method) {
      'POST' => _httpClient.post(uri, headers: headers, body: jsonEncode(body)),
      'GET' => _httpClient.get(uri, headers: headers),
      _ => throw ArgumentError.value(method, 'method', 'Unsupported method'),
    };
  }

  ApiException _mapApiException(http.Response response) {
    var code = 'http_${response.statusCode}';
    var message = 'Backend request failed with HTTP ${response.statusCode}.';

    final body = response.body;
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          final directCode = decoded['code'];
          final directMessage = decoded['message'];
          final error = decoded['error'];

          if (directCode is String && directCode.trim().isNotEmpty) {
            code = directCode;
          }
          if (directMessage is String && directMessage.trim().isNotEmpty) {
            message = directMessage;
          }
          if (error is Map<String, dynamic>) {
            final nestedCode = error['code'];
            final nestedMessage = error['message'];
            if (nestedCode is String && nestedCode.trim().isNotEmpty) {
              code = nestedCode;
            }
            if (nestedMessage is String && nestedMessage.trim().isNotEmpty) {
              message = nestedMessage;
            }
          } else if (error is String && error.trim().isNotEmpty) {
            message = error;
          }
        }
      } catch (_) {
        // Ignore malformed response bodies and preserve the default message.
      }
    }

    return ApiException(
      code: code,
      message: message,
      statusCode: response.statusCode,
      rawBody: body,
    );
  }
}
