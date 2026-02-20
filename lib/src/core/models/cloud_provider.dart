enum CloudProviderType { googleDrive, oneDrive, nextcloud, box }

extension CloudProviderTypeX on CloudProviderType {
  String get key => switch (this) {
    CloudProviderType.googleDrive => 'google_drive',
    CloudProviderType.oneDrive => 'onedrive',
    CloudProviderType.nextcloud => 'nextcloud',
    CloudProviderType.box => 'box',
  };

  String get label => switch (this) {
    CloudProviderType.googleDrive => 'Google Drive',
    CloudProviderType.oneDrive => 'OneDrive',
    CloudProviderType.nextcloud => 'Nextcloud',
    CloudProviderType.box => 'Box',
  };

  static CloudProviderType fromKey(String value) {
    return CloudProviderType.values.firstWhere(
      (type) => type.key == value,
      orElse: () => CloudProviderType.googleDrive,
    );
  }
}
