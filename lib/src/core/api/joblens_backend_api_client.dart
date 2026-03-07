import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'backend_api_models.dart';
import 'backend_auth.dart';

class JoblensBackendApiClient {
  JoblensBackendApiClient({
    required String baseUrl,
    required AccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
  }) : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
       _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client();

  final String _baseUrl;
  final AccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;

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

  Future<UploadUrlResponse> requestUploadUrl(UploadUrlRequest request) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/upload-url',
      body: request.toMap(),
    );
    return UploadUrlResponse.fromMap(map);
  }

  Future<CommitAssetResponse> commitAsset(CommitAssetRequest request) async {
    final map = await _authorizedJsonRequest(
      method: 'POST',
      path: '/assets/commit',
      body: request.toMap(),
    );
    return CommitAssetResponse.fromMap(map);
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
    return SignedMediaUrlResponse.fromMap(map);
  }

  Future<SignedMediaUrlResponse> getDownloadUrl(String assetId) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets/$assetId/download-url',
    );
    return SignedMediaUrlResponse.fromMap(map);
  }

  Future<SignedMediaUrlResponse> getVideoPreviewUrl(String assetId) async {
    final map = await _authorizedJsonRequest(
      method: 'GET',
      path: '/assets/$assetId/video-preview-url',
    );
    return SignedMediaUrlResponse.fromMap(map);
  }

  Future<void> uploadToSignedUrl({
    required String signedUrl,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final response = await _httpClient.put(
      Uri.parse(signedUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );

    final status = response.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return;
    }

    throw ApiException(
      code: 'upload_failed',
      message: 'Signed URL upload failed with HTTP $status.',
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
        // Keep default parsed values.
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
