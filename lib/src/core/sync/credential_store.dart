import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/cloud_provider.dart';
import '../models/provider_credentials.dart';

class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<void> save(
    CloudProviderType provider,
    ProviderCredentials credentials,
  ) async {
    await _storage.write(key: _key(provider), value: credentials.toJson());
  }

  Future<ProviderCredentials?> read(CloudProviderType provider) async {
    final value = await _storage.read(key: _key(provider));
    if (value == null || value.isEmpty) {
      return null;
    }

    final parsed = ProviderCredentials.fromJson(value);
    if (parsed.provider != provider) {
      return ProviderCredentials(
        provider: provider,
        accessToken: parsed.accessToken,
        serverUrl: parsed.serverUrl,
        username: parsed.username,
        appPassword: parsed.appPassword,
      );
    }

    return parsed;
  }

  Future<void> clear(CloudProviderType provider) async {
    await _storage.delete(key: _key(provider));
  }

  Future<Map<CloudProviderType, bool>> hasCredentials() async {
    final status = <CloudProviderType, bool>{};
    for (final provider in CloudProviderType.values) {
      final creds = await read(provider);
      status[provider] = creds?.isConfigured ?? false;
    }
    return status;
  }

  String _key(CloudProviderType provider) =>
      'joblens.credentials.${provider.key}';
}
