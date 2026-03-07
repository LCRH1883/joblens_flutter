import 'package:flutter/foundation.dart';

import 'backend_api_models.dart';

enum SignedMediaUrlKind { thumbnail, download, videoPreview }

class SignedMediaUrlCache {
  SignedMediaUrlCache({
    Duration? defaultTtl,
    Duration? safetyMargin,
  }) : _defaultTtl = defaultTtl ?? const Duration(minutes: 5),
       _safetyMargin = safetyMargin ?? const Duration(seconds: 30);

  final Duration _defaultTtl;
  final Duration _safetyMargin;
  final Map<String, _SignedMediaCacheEntry> _entries =
      <String, _SignedMediaCacheEntry>{};

  Future<String?> resolve({
    required String assetId,
    required SignedMediaUrlKind kind,
    required Future<SignedMediaUrlResponse> Function() loader,
    bool forceRefresh = false,
  }) async {
    final key = _cacheKey(assetId, kind);
    final cached = _entries[key];
    if (!forceRefresh && cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.url;
    }

    final response = await loader();
    final ttl = response.ttlSec <= 0 ? _defaultTtl : Duration(seconds: response.ttlSec);
    var expiresAt = DateTime.now().add(ttl).subtract(_safetyMargin);
    if (expiresAt.isBefore(DateTime.now())) {
      expiresAt = DateTime.now().add(const Duration(seconds: 10));
    }

    _entries[key] = _SignedMediaCacheEntry(url: response.url, expiresAt: expiresAt);
    return response.url;
  }

  void invalidate(String assetId, SignedMediaUrlKind kind) {
    _entries.remove(_cacheKey(assetId, kind));
  }

  @visibleForTesting
  bool hasValid(String assetId, SignedMediaUrlKind kind) {
    final entry = _entries[_cacheKey(assetId, kind)];
    return entry != null && entry.expiresAt.isAfter(DateTime.now());
  }

  String _cacheKey(String assetId, SignedMediaUrlKind kind) => '$assetId:${kind.name}';
}

class _SignedMediaCacheEntry {
  const _SignedMediaCacheEntry({
    required this.url,
    required this.expiresAt,
  });

  final String url;
  final DateTime expiresAt;
}
