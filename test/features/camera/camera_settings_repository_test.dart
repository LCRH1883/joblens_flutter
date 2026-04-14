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
}
