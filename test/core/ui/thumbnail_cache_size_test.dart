import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/ui/thumbnail_cache_size.dart';

void main() {
  test('thumbnailCacheDimension scales widget size by device pixel ratio', () {
    expect(thumbnailCacheDimension(logicalSize: 56, devicePixelRatio: 3), 168);
  });

  test(
    'thumbnailCacheDimension clamps decoded size to the thumbnail ceiling',
    () {
      expect(
        thumbnailCacheDimension(logicalSize: 320, devicePixelRatio: 3),
        512,
      );
    },
  );

  test('thumbnailCacheDimension normalizes invalid or non-positive input', () {
    expect(thumbnailCacheDimension(logicalSize: 0, devicePixelRatio: 0), 1);
    expect(
      thumbnailCacheDimension(logicalSize: double.nan, devicePixelRatio: -2),
      1,
    );
  });
}
