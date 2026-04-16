import 'package:flutter/services.dart' show rootBundle;

const _kDefaultEmailAuthCallbackPath = '/functions/v1/api/v1/auth/callback';
const _kAppAuthRedirectUri = 'joblens://auth-callback';

class AppRuntimeConfiguration {
  const AppRuntimeConfiguration({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.apiBaseUrlOverride,
  });

  final String supabaseUrl;
  final String supabaseAnonKey;
  final String apiBaseUrlOverride;

  static Future<AppRuntimeConfiguration> load() async {
    final compileTimeConfig = AppRuntimeConfiguration(
      supabaseUrl: _firstNonEmpty(
        const String.fromEnvironment('SUPABASE_URL'),
        const String.fromEnvironment('JOBLENS_SUPABASE_URL'),
      ),
      supabaseAnonKey: _firstNonEmpty(
        const String.fromEnvironment('SUPABASE_ANON_KEY'),
        const String.fromEnvironment('JOBLENS_SUPABASE_ANON_KEY'),
      ),
      apiBaseUrlOverride: const String.fromEnvironment('API_BASE_URL').trim(),
    );

    final assetValues = await _tryLoadDotEnvAsset();
    if (assetValues.isEmpty) {
      return compileTimeConfig;
    }

    return AppRuntimeConfiguration(
      supabaseUrl: _firstNonEmpty(
        compileTimeConfig.supabaseUrl,
        _firstNonEmpty(
          assetValues['SUPABASE_URL'] ?? '',
          assetValues['JOBLENS_SUPABASE_URL'] ?? '',
        ),
      ),
      supabaseAnonKey: _firstNonEmpty(
        compileTimeConfig.supabaseAnonKey,
        _firstNonEmpty(
          assetValues['SUPABASE_ANON_KEY'] ?? '',
          assetValues['JOBLENS_SUPABASE_ANON_KEY'] ?? '',
        ),
      ),
      apiBaseUrlOverride: _firstNonEmpty(
        compileTimeConfig.apiBaseUrlOverride,
        assetValues['API_BASE_URL'] ?? '',
      ),
    );
  }

  bool get isConfigured =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  bool get isFullyConfigured => isConfigured && apiBaseUrl.trim().isNotEmpty;

  String get apiBaseUrl => apiBaseUrlOverride.trim().isNotEmpty
      ? apiBaseUrlOverride.trim()
      : '${supabaseUrl.trim()}/functions/v1/api/v1';

  String get emailAuthRedirectUri {
    if (apiBaseUrl.trim().isNotEmpty) {
      return Uri.parse(apiBaseUrl).resolve('auth/callback').toString();
    }
    if (supabaseUrl.trim().isNotEmpty) {
      return Uri.parse(
        supabaseUrl.trim(),
      ).resolve(_kDefaultEmailAuthCallbackPath).toString();
    }
    return _kAppAuthRedirectUri;
  }

  static Future<Map<String, String>> _tryLoadDotEnvAsset() async {
    try {
      final raw = await rootBundle.loadString('.env');
      return _parseDotEnv(raw);
    } catch (_) {
      return const <String, String>{};
    }
  }

  static Map<String, String> _parseDotEnv(String raw) {
    final values = <String, String>{};
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final separator = line.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final key = line.substring(0, separator).trim();
      if (key.isEmpty) {
        continue;
      }
      final value = line.substring(separator + 1).trim();
      values[key] = _stripWrappingQuotes(value);
    }
    return values;
  }

  static String _stripWrappingQuotes(String value) {
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '\'' && last == '\'') || (first == '"' && last == '"')) {
        return value.substring(1, value.length - 1).trim();
      }
    }
    return value.trim();
  }
}

String _firstNonEmpty(String primary, String fallback) {
  final primaryTrimmed = primary.trim();
  if (primaryTrimmed.isNotEmpty) {
    return primaryTrimmed;
  }
  return fallback.trim();
}
