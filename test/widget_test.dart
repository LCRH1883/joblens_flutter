import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/models/app_launch_destination.dart';

void main() {
  test('app launch destination round-trips through storage values', () {
    expect(
      AppLaunchDestination.fromStorage(
        AppLaunchDestination.camera.storageValue,
      ),
      AppLaunchDestination.camera,
    );
    expect(
      AppLaunchDestination.fromStorage(
        AppLaunchDestination.projects.storageValue,
      ),
      AppLaunchDestination.projects,
    );
    expect(AppLaunchDestination.fromStorage('unknown'), isNull);
  });
}
