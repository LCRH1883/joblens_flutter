import '../../models/cloud_provider.dart';

class OAuthProviderConfig {
  const OAuthProviderConfig({
    required this.provider,
    required this.clientId,
    required this.redirectUri,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.scopes,
    this.additionalParameters,
  });

  final CloudProviderType provider;
  final String clientId;
  final String redirectUri;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final List<String> scopes;
  final Map<String, String>? additionalParameters;

  bool get isConfigured => clientId.trim().isNotEmpty;

  static OAuthProviderConfig? forProvider(CloudProviderType provider) {
    const redirectUri = String.fromEnvironment(
      'JOBLENS_OAUTH_REDIRECT_URI',
      defaultValue: 'joblens:/oauth2redirect',
    );

    switch (provider) {
      case CloudProviderType.googleDrive:
        return OAuthProviderConfig(
          provider: provider,
          clientId: const String.fromEnvironment('JOBLENS_GOOGLE_CLIENT_ID'),
          redirectUri: redirectUri,
          authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
          tokenEndpoint: 'https://oauth2.googleapis.com/token',
          scopes: const [
            'openid',
            'email',
            'profile',
            'https://www.googleapis.com/auth/drive.file',
          ],
          additionalParameters: const {
            'access_type': 'offline',
            'prompt': 'consent',
          },
        );
      case CloudProviderType.oneDrive:
        const tenant = String.fromEnvironment(
          'JOBLENS_ONEDRIVE_TENANT',
          defaultValue: 'common',
        );
        return OAuthProviderConfig(
          provider: provider,
          clientId: const String.fromEnvironment('JOBLENS_ONEDRIVE_CLIENT_ID'),
          redirectUri: redirectUri,
          authorizationEndpoint:
              'https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize',
          tokenEndpoint:
              'https://login.microsoftonline.com/$tenant/oauth2/v2.0/token',
          scopes: const [
            'openid',
            'profile',
            'offline_access',
            'User.Read',
            'Files.ReadWrite',
          ],
        );
      case CloudProviderType.box:
        return OAuthProviderConfig(
          provider: provider,
          clientId: const String.fromEnvironment('JOBLENS_BOX_CLIENT_ID'),
          redirectUri: redirectUri,
          authorizationEndpoint: 'https://account.box.com/api/oauth2/authorize',
          tokenEndpoint: 'https://api.box.com/oauth2/token',
          scopes: const <String>[],
        );
      case CloudProviderType.nextcloud:
        return null;
    }
  }
}
