import 'dart:convert';
import 'dart:async';
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

  test('register device parses device session payload', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'device': {
              'id': 'device-1',
            },
            'isCurrent': true,
            'deviceSessionId': 'session-1',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.registerDevice(
      clientDeviceId: 'client-1',
      platform: 'ios',
      deviceName: 'iPhone',
      osVersion: '18.4',
    );

    expect(response.deviceId, 'device-1');
    expect(response.isCurrent, isTrue);
    expect(response.deviceSessionId, 'session-1');
  });

  test('lists signed-in devices', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'devices': [
              {
                'deviceId': 'device-1',
                'deviceName': 'John’s iPhone',
                'platform': 'ios',
                'osVersion': '18.4',
                'appVersion': '1.0.0',
                'approxLocation': {
                  'city': 'Vancouver',
                  'region': 'BC',
                  'countryCode': 'CA',
                  'display': 'Vancouver, BC, CA',
                },
                'signedInAt': '2026-04-11T10:00:00.000Z',
                'lastSeenAt': '2026-04-11T11:00:00.000Z',
                'isCurrent': true,
                'canSignOut': false,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.listDevices();
    expect(response.devices, hasLength(1));
    expect(response.devices.single.deviceName, 'John’s iPhone');
    expect(response.devices.single.approxLocation?.display, 'Vancouver, BC, CA');
    expect(response.devices.single.isCurrent, isTrue);
    expect(response.devices.single.canSignOut, isFalse);
  });

  test('gets device session status', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'status': 'revoked',
            'reason': 'remote_user_signout',
            'message': 'You were signed out from another device.',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.getSessionStatus();
    expect(response.isRevoked, isTrue);
    expect(response.reason, 'remote_user_signout');
  });

  test('updates device activity with sync heartbeat fields', () async {
    late Uri requestUri;
    late String requestMethod;
    late Map<String, dynamic> requestBody;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        requestUri = request.url;
        requestMethod = request.method;
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'device': {'id': 'device-1'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await client.updateDeviceActivity(
      deviceId: 'device-1',
      lastSyncEventId: 42,
      markSyncAt: true,
    );

    expect(requestMethod, 'PATCH');
    expect(requestUri.path, '/functions/v1/api/v1/devices/device-1');
    expect(requestBody, {
      'lastSyncEventId': 42,
      'markSyncAt': true,
    });
  });

  test('move asset omits expectedRevision when null', () async {
    late Uri requestUri;
    late String requestMethod;
    late Map<String, dynamic> requestBody;
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        requestUri = request.url;
        requestMethod = request.method;
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'assetId': 'asset-1',
            'projectId': 'project-2',
            'revision': 7,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.moveAssetToProject(
      assetId: 'asset-1',
      projectId: 'project-2',
    );

    expect(requestMethod, 'POST');
    expect(requestUri.path, '/functions/v1/api/v1/assets/asset-1/move');
    expect(requestBody, {
      'projectId': 'project-2',
    });
    expect(response.assetId, 'asset-1');
    expect(response.projectId, 'project-2');
    expect(response.revision, 7);
  });

  test('returns remote file id from final chunked upload response', () async {
    final requests = <http.Request>[];
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'onedrive-item-42',
            'name': 'photo.jpg',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.uploadWithInstruction(
      instruction: DirectUploadInstruction(
        strategy: 'chunked_put',
        url: 'https://upload.example/onedrive-session',
        method: 'PUT',
        headers: const {},
        fields: const {},
        fileFieldName: 'file',
        chunkSizeBytes: 1024,
      ),
      bytes: Uint8List.fromList(List<int>.generate(256, (i) => i)),
      contentType: 'image/jpeg',
      filename: 'photo.jpg',
    );

    expect(requests, hasLength(1));
    expect(result.remoteFileId, 'onedrive-item-42');
    expect(result.rawResponse?['id'], 'onedrive-item-42');
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

  test('backend requests time out instead of hanging forever', () async {
    final completer = Completer<http.Response>();
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      backendRequestTimeout: const Duration(milliseconds: 10),
      httpClient: MockClient((request) => completer.future),
    );

    await expectLater(
      client.listDevices(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'backend_request_timeout',
        ),
      ),
    );
  });

  test('direct uploads time out instead of hanging forever', () async {
    final completer = Completer<http.Response>();
    final client = JoblensBackendApiClient(
      baseUrl: 'https://api.joblens.xyz/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      directUploadTimeout: const Duration(milliseconds: 10),
      httpClient: MockClient((request) => completer.future),
    );

    await expectLater(
      client.uploadWithInstruction(
        instruction: DirectUploadInstruction(
          strategy: 'single_put',
          url: 'https://upload.example/file',
          method: 'PUT',
          headers: const {},
          fields: const {},
          fileFieldName: 'file',
        ),
        bytes: Uint8List.fromList([1, 2, 3]),
        contentType: 'image/jpeg',
        filename: 'photo.jpg',
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'direct_upload_timeout',
        ),
      ),
    );
  });
}

class _FakeTokenProvider implements AccessTokenProvider {
  const _FakeTokenProvider(this._token);

  final String _token;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => _token;
}
