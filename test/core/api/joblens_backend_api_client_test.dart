import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:joblens_flutter/src/core/api/api_exception.dart';
import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/api/backend_auth.dart';
import 'package:joblens_flutter/src/core/api/joblens_backend_api_client.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';

void main() {
  test('adds authorization header to backend requests', () async {
    late http.BaseRequest capturedRequest;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'projectId': 'project-1',
            'results': const [],
            'duplicateCount': 0,
            'missingCount': 0,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.bulkCheckAssets(
      projectId: 'project-1',
      assets: [BulkCheckAssetInput(deviceAssetId: 'asset-1', sha256: 'a' * 64)],
    );

    expect(capturedRequest.headers['authorization'], 'Bearer token-123');
  });

  test('provider connect sends backend callback and app redirect', () async {
    late Map<String, dynamic> capturedBody;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'provider': 'dropbox',
            'sessionId': 'session-123',
            'launchUrl': 'https://www.dropbox.com/oauth2/authorize?state=abc',
            'expiresAt': '2026-04-08T20:00:00.000Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.beginProviderConnection(
      CloudProviderType.dropbox,
      intent: 'connect',
    );

    expect(
      capturedBody,
      {
        'redirectUri':
            'https://api.joblens.xyz/functions/v1/api/v1/providers/dropbox/oauth/callback',
        'intent': 'connect',
        'mobileReturnUrl': 'https://auth.joblens.app/mobile/provider-callback',
        'redirectTo': 'joblens://auth-callback',
      },
    );
    expect(
      response.authorizationUrl,
      'https://www.dropbox.com/oauth2/authorize?state=abc',
    );
  });

  test('parses provider connection identity fields', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'connections': [
              {
                'provider': 'dropbox',
                'status': 'connected',
                'displayName': 'John Appleseed',
                'accountIdentifier': 'john@example.com',
                'connectedAt': '2026-04-08T20:00:00.000Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.listProviderConnections();
    expect(response.connections, hasLength(1));
    expect(response.connections.single.provider, CloudProviderType.dropbox);
    expect(response.connections.single.displayName, 'John Appleseed');
    expect(
      response.connections.single.accountIdentifier,
      'john@example.com',
    );
  });

  test('project reconcile posts to the existing backend endpoint', () async {
    late Uri requestUri;
    late String requestMethod;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        requestUri = request.url;
        requestMethod = request.method;
        return http.Response(
          jsonEncode({
            'projectId': 'remote-project-1',
            'enqueued': true,
            'targetCount': 1,
            'warnings': const [],
          }),
          202,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.reconcileProject('remote-project-1');

    expect(requestMethod, 'POST');
    expect(
      requestUri.toString(),
      'https://api.joblens.xyz/functions/v1/api/v1/projects/remote-project-1/reconcile',
    );
  });

  test('maps uploaded_object_not_found backend error', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': 'uploaded_object_not_found',
            'message': 'Uploaded object not found.',
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      () => client.commitAsset(
        CommitAssetRequest(
          projectId: 'project-1',
          sha256: 'a' * 64,
          mediaType: 'photo',
          bytes: 123,
          remotePath: 'Joblens/Library/file.jpg',
        ),
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'uploaded_object_not_found',
        ),
      ),
    );
  });

  test('maps idempotency_key_reuse_mismatch backend error', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'idempotency_key_reuse_mismatch',
              'message': 'Idempotency key mismatch.',
            },
          }),
          409,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      () => client.commitAsset(
        CommitAssetRequest(
          projectId: 'project-1',
          sha256: 'a' * 64,
          mediaType: 'photo',
          bytes: 123,
          remotePath: 'Joblens/Library/file.jpg',
        ),
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'idempotency_key_reuse_mismatch',
        ),
      ),
    );
  });

  test('parses signed media URL aliases and default ttl', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'signedUrl': 'https://cdn.example/thumb.jpg'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.getThumbnailUrl('asset-1');
    expect(response.url, 'https://cdn.example/thumb.jpg');
    expect(response.ttlSec, 300);
  });

  test('rewrites internal backend media proxy URLs onto the public API host', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'url':
                'http://supabase_edge_runtime_backend:8081/functions/v1/api/v1/media/asset-1/thumbnail?token=abc',
            'ttlSec': 300,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.getThumbnailUrl('asset-1');
    expect(
      response.url,
      'https://api.joblens.xyz/functions/v1/api/v1/media/asset-1/thumbnail?token=abc',
    );
  });

  test('downloads asset bytes through normalized proxy URL', () async {
    var requestCount = 0;
    late Uri downloadedUri;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        requestCount += 1;
        if (requestCount == 1) {
          return http.Response(
            jsonEncode({
              'url':
                  'http://supabase_edge_runtime_backend:8081/functions/v1/api/v1/media/asset-1/original?token=xyz',
              'ttlSec': 300,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        downloadedUri = request.url;
        return http.Response.bytes(
          Uint8List.fromList([1, 2, 3]),
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }),
    );

    final bytes = await client.downloadAssetBytes('asset-1');
    expect(bytes, Uint8List.fromList([1, 2, 3]));
    expect(
      downloadedUri.toString(),
      'https://api.joblens.xyz/functions/v1/api/v1/media/asset-1/original?token=xyz',
    );
  });
}

class _FakeTokenProvider implements AccessTokenProvider {
  const _FakeTokenProvider(this._token);

  final String _token;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => _token;
}
