enum CloudProviderType {
  googleDrive,
  oneDrive,
  dropbox,
  nextcloud,
  box,
  backend,
}

extension CloudProviderTypeX on CloudProviderType {
  static const userConfigurableProviders = <CloudProviderType>[
    CloudProviderType.googleDrive,
    CloudProviderType.oneDrive,
    CloudProviderType.dropbox,
    CloudProviderType.nextcloud,
    CloudProviderType.box,
  ];

  String get key => switch (this) {
    CloudProviderType.googleDrive => 'google_drive',
    CloudProviderType.oneDrive => 'onedrive',
    CloudProviderType.dropbox => 'dropbox',
    CloudProviderType.nextcloud => 'nextcloud',
    CloudProviderType.box => 'box',
    CloudProviderType.backend => 'backend',
  };

  String get label => switch (this) {
    CloudProviderType.googleDrive => 'Google Drive',
    CloudProviderType.oneDrive => 'OneDrive',
    CloudProviderType.dropbox => 'Dropbox',
    CloudProviderType.nextcloud => 'Nextcloud',
    CloudProviderType.box => 'Box',
    CloudProviderType.backend => 'Backend',
  };

  static CloudProviderType fromKey(String value) {
    return CloudProviderType.values.firstWhere(
      (type) => type.key == value,
      orElse: () => CloudProviderType.googleDrive,
    );
  }
}
