enum AppLaunchDestination {
  camera('camera'),
  projects('projects');

  const AppLaunchDestination(this.storageValue);

  final String storageValue;

  String get label => switch (this) {
    AppLaunchDestination.camera => 'Open to Camera',
    AppLaunchDestination.projects => 'Open to Projects',
  };

  static AppLaunchDestination? fromStorage(String? value) {
    for (final destination in values) {
      if (destination.storageValue == value) {
        return destination;
      }
    }
    return null;
  }
}
