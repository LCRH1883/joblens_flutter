import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:joblens_flutter/src/core/api/api_exception.dart';
import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/api/backend_auth.dart';
import 'package:joblens_flutter/src/core/api/joblens_backend_api_client.dart';

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
      assets: [
        BulkCheckAssetInput(deviceAssetId: 'asset-1', sha256: 'a' * 64),
      ],
    );

    expect(capturedRequest.headers['authorization'], 'Bearer token-123');
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
          uploadPath: 'user/hash/file.jpg',
        ),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'uploaded_object_not_found'),
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
          uploadPath: 'user/hash/file.jpg',
        ),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'idempotency_key_reuse_mismatch'),
      ),
    );
  });

  test('parses signed media URL aliases and default ttl', () async {
    final client = JoblensBackendApiClient(
      baseUrl: 'https://example.supabase.co/functions/v1/api/v1',
      accessTokenProvider: _FakeTokenProvider('token-123'),
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'signedUrl': 'https://cdn.example/thumb.jpg',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final response = await client.getThumbnailUrl('asset-1');
    expect(response.url, 'https://cdn.example/thumb.jpg');
    expect(response.ttlSec, 300);
  });
}

class _FakeTokenProvider implements AccessTokenProvider {
  const _FakeTokenProvider(this._token);

  final String _token;

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async => _token;
}
