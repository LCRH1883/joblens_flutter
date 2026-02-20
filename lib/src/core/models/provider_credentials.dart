import 'dart:convert';

import 'cloud_provider.dart';

class ProviderCredentials {
  const ProviderCredentials({
    required this.provider,
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
    this.tokenType,
    this.serverUrl,
    this.username,
    this.appPassword,
  });

  final CloudProviderType provider;
  final String? accessToken;
  final String? refreshToken;
  final DateTime? accessTokenExpiresAt;
  final String? tokenType;
  final String? serverUrl;
  final String? username;
  final String? appPassword;

  bool get isConfigured {
    return switch (provider) {
      CloudProviderType.googleDrive ||
      CloudProviderType.oneDrive ||
      CloudProviderType.box => hasAccessToken || hasRefreshToken,
      CloudProviderType.nextcloud =>
        serverUrl != null &&
            serverUrl!.trim().isNotEmpty &&
            username != null &&
            username!.trim().isNotEmpty &&
            appPassword != null &&
            appPassword!.trim().isNotEmpty,
    };
  }

  bool get hasAccessToken =>
      accessToken != null && accessToken!.trim().isNotEmpty;
  bool get hasRefreshToken =>
      refreshToken != null && refreshToken!.trim().isNotEmpty;

  bool get isOAuthProvider {
    return provider == CloudProviderType.googleDrive ||
        provider == CloudProviderType.oneDrive ||
        provider == CloudProviderType.box;
  }

  bool get canRefreshAccessToken => isOAuthProvider && hasRefreshToken;

  bool isAccessTokenExpiringSoon({Duration skew = Duration.zero}) {
    final expiry = accessTokenExpiresAt;
    if (expiry == null) {
      return false;
    }
    return expiry.isBefore(DateTime.now().add(skew));
  }

  ProviderCredentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    String? tokenType,
    String? serverUrl,
    String? username,
    String? appPassword,
  }) {
    return ProviderCredentials(
      provider: provider,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      tokenType: tokenType ?? this.tokenType,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      appPassword: appPassword ?? this.appPassword,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'provider': provider.key,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessTokenExpiresAt': accessTokenExpiresAt?.toIso8601String(),
      'tokenType': tokenType,
      'serverUrl': serverUrl,
      'username': username,
      'appPassword': appPassword,
    };
  }

  String toJson() => jsonEncode(toMap());

  factory ProviderCredentials.fromMap(Map<String, dynamic> map) {
    return ProviderCredentials(
      provider: CloudProviderTypeX.fromKey(map['provider'] as String),
      accessToken: map['accessToken'] as String?,
      refreshToken: map['refreshToken'] as String?,
      accessTokenExpiresAt: map['accessTokenExpiresAt'] == null
          ? null
          : DateTime.parse(map['accessTokenExpiresAt'] as String),
      tokenType: map['tokenType'] as String?,
      serverUrl: map['serverUrl'] as String?,
      username: map['username'] as String?,
      appPassword: map['appPassword'] as String?,
    );
  }

  factory ProviderCredentials.fromJson(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return ProviderCredentials.fromMap(map);
  }
}
