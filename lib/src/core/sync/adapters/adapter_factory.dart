import '../../models/cloud_provider.dart';
import '../../models/provider_credentials.dart';
import '../cloud_adapter.dart';
import 'box_adapter.dart';
import 'google_drive_adapter.dart';
import 'nextcloud_adapter.dart';
import 'onedrive_adapter.dart';

CloudAdapter? buildAdapter(ProviderCredentials? credentials) {
  if (credentials == null || !credentials.isConfigured) {
    return null;
  }

  return switch (credentials.provider) {
    CloudProviderType.googleDrive => GoogleDriveAdapter(
      accessToken: credentials.accessToken!,
    ),
    CloudProviderType.oneDrive => OneDriveAdapter(
      accessToken: credentials.accessToken!,
    ),
    CloudProviderType.dropbox => null,
    CloudProviderType.box => BoxAdapter(accessToken: credentials.accessToken!),
    CloudProviderType.nextcloud => NextcloudAdapter(
      serverUrl: credentials.serverUrl!,
      username: credentials.username!,
      appPassword: credentials.appPassword!,
    ),
    CloudProviderType.backend => null,
  };
}
