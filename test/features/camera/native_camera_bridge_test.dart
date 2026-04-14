import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/features/camera/native_camera_bridge.dart';

void main() {
  test('NativeCameraSessionEvent parses bridge duration events', () {
    final lensSwitch = NativeCameraSessionEvent.fromDynamic({
      'type': 'lensSwitchCompleted',
      'sessionId': 'session-1',
      'durationMs': 187,
    });
    final targetPicker = NativeCameraSessionEvent.fromDynamic({
      'type': 'targetPickerFailed',
      'sessionId': 'session-1',
      'message': 'Unable to open capture target picker.',
    });

    expect(lensSwitch.type, NativeCameraEventType.lensSwitchCompleted);
    expect(lensSwitch.sessionId, 'session-1');
    expect(lensSwitch.durationMs, 187);

    expect(targetPicker.type, NativeCameraEventType.targetPickerFailed);
    expect(targetPicker.sessionId, 'session-1');
    expect(targetPicker.message, 'Unable to open capture target picker.');
  });
}
