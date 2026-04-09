import '../../core/models/cloud_provider.dart';

class ProviderOAuthCallback {
  const ProviderOAuthCallback({
    required this.provider,
    required this.status,
    this.sessionId,
    this.code,
    this.message,
    this.accountIdentifier,
  });

  final CloudProviderType provider;
  final String status;
  final String? sessionId;
  final String? code;
  final String? message;
  final String? accountIdentifier;

  bool get isSuccess => status == 'success';

  static ProviderOAuthCallback? tryParse(Uri uri) {
    final isCustomScheme = uri.scheme == 'joblens' && uri.host == 'auth-callback';
    final isWebCallback =
        uri.scheme == 'https' &&
        uri.host == 'auth.joblens.app' &&
        uri.path == '/mobile/provider-callback';
    if (!isCustomScheme && !isWebCallback) {
      return null;
    }

    final parameters = _extractParameters(uri);
    final providerKey = parameters['provider']?.trim();
    final status = parameters['status']?.trim().toLowerCase();
    if (status == null || status.isEmpty) {
      return null;
    }

    final provider = providerKey == null || providerKey.isEmpty
        ? null
        : _providerFromKey(providerKey);
    if (provider == null && _normalizedValue(parameters['sid']) == null) {
      return null;
    }
    final resolvedProvider = provider ?? CloudProviderType.dropbox;
    if (provider == null) {
      // Provider-specific session details are fetched from the backend using sid.
    }

    return ProviderOAuthCallback(
      provider: resolvedProvider,
      status: status,
      sessionId: _normalizedValue(parameters['sid'] ?? parameters['sessionId']),
      code: _normalizedValue(parameters['code']),
      message: _normalizedValue(parameters['message']),
      accountIdentifier: _normalizedValue(parameters['accountIdentifier']),
    );
  }

  String userFacingMessage() {
    if (isSuccess) {
      final account = accountIdentifier?.trim();
      if (account != null && account.isNotEmpty) {
        return '${provider.label} connected as $account.';
      }
      return '${provider.label} connected.';
    }

    final detail = _normalizedValue(message) ?? _normalizedValue(code);
    if (detail == null) {
      return '${provider.label} connection did not complete.';
    }

    return '${provider.label} connection did not complete: ${_humanize(detail)}.';
  }

  static Map<String, String> _extractParameters(Uri uri) {
    final parameters = <String, String>{...uri.queryParameters};
    final fragment = uri.fragment.trim();
    if (fragment.isEmpty || !fragment.contains('=')) {
      return parameters;
    }

    final fragmentParameters = Uri.splitQueryString(fragment);
    for (final entry in fragmentParameters.entries) {
      parameters.putIfAbsent(entry.key, () => entry.value);
    }
    return parameters;
  }

  static CloudProviderType? _providerFromKey(String value) {
    for (final provider in CloudProviderType.values) {
      if (provider.key == value) {
        return provider;
      }
    }
    return null;
  }

  static String? _normalizedValue(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  static String _humanize(String value) {
    return value.replaceAll(RegExp(r'[_-]+'), ' ');
  }
}
