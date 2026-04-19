int thumbnailCacheDimension({
  required double logicalSize,
  required double devicePixelRatio,
  int maxDimension = 512,
}) {
  final normalizedLogicalSize = logicalSize.isFinite && logicalSize > 0
      ? logicalSize
      : 1.0;
  final normalizedDevicePixelRatio =
      devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  final physicalSize = (normalizedLogicalSize * normalizedDevicePixelRatio)
      .ceil();
  return physicalSize.clamp(1, maxDimension);
}
