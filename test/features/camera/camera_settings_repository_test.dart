import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/features/camera/camera_settings_repository.dart';

void main() {
  test('back camera persisted zoom below 1.0 is clamped to 1.0', () {
    final settings = CameraSettings.fromJson({
      'lensDirection': 'back',
      'zoomStop': 0.5,
    });

    expect(settings.lensDirection, CameraLensDirection.back);
    expect(settings.zoomStop, 1.0);
  });

  test('front camera preserves persisted zoom value', () {
    final settings = CameraSettings.fromJson({
      'lensDirection': 'front',
      'zoomStop': 1.3,
    });

    expect(settings.lensDirection, CameraLensDirection.front);
    expect(settings.zoomStop, 1.3);
  });

  test('normalizedForLaunch resets rear camera to 1.0x', () {
    const settings = CameraSettings(
      rapidCaptureMode: true,
      flashMode: FlashMode.off,
      lensDirection: CameraLensDirection.back,
      zoomStop: 2.0,
    );

    final normalized = settings.normalizedForLaunch();

    expect(normalized.lensDirection, CameraLensDirection.back);
    expect(normalized.zoomStop, 1.0);
  });

  test('normalizedForLaunch preserves front camera zoom', () {
    const settings = CameraSettings(
      rapidCaptureMode: true,
      flashMode: FlashMode.off,
      lensDirection: CameraLensDirection.front,
      zoomStop: 1.3,
    );

    final normalized = settings.normalizedForLaunch();

    expect(normalized.lensDirection, CameraLensDirection.front);
    expect(normalized.zoomStop, 1.3);
  });
}
