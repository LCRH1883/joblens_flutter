import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/api/signed_media_url_cache.dart';

void main() {
  test('caches signed url until ttl expiry', () async {
    final cache = SignedMediaUrlCache(
      defaultTtl: const Duration(milliseconds: 120),
      safetyMargin: Duration.zero,
    );
    var loads = 0;

    Future<SignedMediaUrlResponse> loader() async {
      loads += 1;
      return SignedMediaUrlResponse(
        url: 'https://cdn.example/$loads',
        ttlSec: 0,
      );
    }

    final first = await cache.resolve(
      assetId: 'asset-1',
      kind: SignedMediaUrlKind.thumbnail,
      loader: loader,
    );
    final second = await cache.resolve(
      assetId: 'asset-1',
      kind: SignedMediaUrlKind.thumbnail,
      loader: loader,
    );

    expect(first, 'https://cdn.example/1');
    expect(second, 'https://cdn.example/1');
    expect(loads, 1);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    final third = await cache.resolve(
      assetId: 'asset-1',
      kind: SignedMediaUrlKind.thumbnail,
      loader: loader,
    );

    expect(third, 'https://cdn.example/2');
    expect(loads, 2);
  });

  test('forceRefresh bypasses cache entry', () async {
    final cache = SignedMediaUrlCache(safetyMargin: Duration.zero);
    var loads = 0;

    Future<SignedMediaUrlResponse> loader() async {
      loads += 1;
      return SignedMediaUrlResponse(
        url: 'https://cdn.example/$loads',
        ttlSec: 300,
      );
    }

    final first = await cache.resolve(
      assetId: 'asset-1',
      kind: SignedMediaUrlKind.download,
      loader: loader,
    );
    final refreshed = await cache.resolve(
      assetId: 'asset-1',
      kind: SignedMediaUrlKind.download,
      loader: loader,
      forceRefresh: true,
    );

    expect(first, 'https://cdn.example/1');
    expect(refreshed, 'https://cdn.example/2');
    expect(loads, 2);
  });
}
