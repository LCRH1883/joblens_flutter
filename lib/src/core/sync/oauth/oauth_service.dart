import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import '../../models/cloud_provider.dart';
import '../../models/provider_credentials.dart';
import '../cloud_adapter.dart';
import 'oauth_provider_config.dart';

class OAuthService {
  OAuthService({FlutterAppAuth? appAuth})
    : _appAuth = appAuth ?? FlutterAppAuth();

  final FlutterAppAuth _appAuth;

  Future<ProviderCredentials> authorize(CloudProviderType provider) async {
    final config = OAuthProviderConfig.forProvider(provider);
    if (config == null) {
      throw CloudSyncException(
        '${provider.label} does not use OAuth in this app.',
      );
    }

    if (!config.isConfigured) {
      throw CloudSyncException(
        'Missing OAuth client ID for ${provider.label}. '
        'Pass it via --dart-define when running/building the app.',
      );
    }

    try {
      final request = AuthorizationTokenRequest(
        config.clientId,
        config.redirectUri,
        serviceConfiguration: AuthorizationServiceConfiguration(
          authorizationEndpoint: config.authorizationEndpoint,
          tokenEndpoint: config.tokenEndpoint,
        ),
        scopes: config.scopes.isEmpty ? null : config.scopes,
        promptValues: const ['consent'],
        additionalParameters: config.additionalParameters,
      );

      final response = await _appAuth.authorizeAndExchangeCode(request);
      final accessToken = response.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        throw const CloudSyncException('OAuth finished without access token.');
      }

      return ProviderCredentials(
        provider: provider,
        accessToken: accessToken,
        refreshToken: response.refreshToken,
        accessTokenExpiresAt: response.accessTokenExpirationDateTime,
        tokenType: response.tokenType,
      );
    } on PlatformException catch (error) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        throw CloudSyncException('OAuth failed: $message');
      }
      throw CloudSyncException('OAuth failed: ${error.code}');
    }
  }

  Future<ProviderCredentials> refreshAccessToken(
    ProviderCredentials current,
  ) async {
    final provider = current.provider;
    final config = OAuthProviderConfig.forProvider(provider);
    if (config == null) {
      throw CloudSyncException(
        '${provider.label} does not support OAuth token refresh in this app.',
      );
    }

    if (!config.isConfigured) {
      throw CloudSyncException(
        'Missing OAuth client ID for ${provider.label}. '
        'Pass it via --dart-define when running/building the app.',
      );
    }

    final refreshToken = current.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw CloudSyncException(
        'No refresh token available for ${provider.label}. Re-authenticate.',
      );
    }

    try {
      final tokenRequest = TokenRequest(
        config.clientId,
        config.redirectUri,
        serviceConfiguration: AuthorizationServiceConfiguration(
          authorizationEndpoint: config.authorizationEndpoint,
          tokenEndpoint: config.tokenEndpoint,
        ),
        refreshToken: refreshToken,
        scopes: config.scopes.isEmpty ? null : config.scopes,
      );

      final response = await _appAuth.token(tokenRequest);
      final nextAccessToken = response.accessToken;
      if (nextAccessToken == null || nextAccessToken.isEmpty) {
        throw const CloudSyncException(
          'Token refresh completed without access token.',
        );
      }

      return current.copyWith(
        accessToken: nextAccessToken,
        refreshToken: (response.refreshToken ?? '').isNotEmpty
            ? response.refreshToken
            : current.refreshToken,
        accessTokenExpiresAt: response.accessTokenExpirationDateTime,
        tokenType: response.tokenType,
      );
    } on PlatformException catch (error) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        throw CloudSyncException('Token refresh failed: $message');
      }
      throw CloudSyncException('Token refresh failed: ${error.code}');
    }
  }
}
