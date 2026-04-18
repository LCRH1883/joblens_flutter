import 'package:flutter/services.dart' show rootBundle;

const _kDefaultApiBasePath = '/functions/v1/api/v1';
const _kDefaultEmailAuthCallbackPath = '/functions/v1/api/v1/auth/callback';
const _kAppAuthRedirectUri = 'joblens://auth-callback';

enum JoblensAppEnvironment {
  dev(name: 'dev', supabaseUrl: 'https://dev.joblens.xyz'),
  prod(name: 'prod', supabaseUrl: 'https://api.joblens.xyz');

  const JoblensAppEnvironment({required this.name, required this.supabaseUrl});

  final String name;
  final String supabaseUrl;

  String get apiBaseUrl => '$supabaseUrl$_kDefaultApiBasePath';

  static JoblensAppEnvironment? tryParse(String value) {
    final normalized = value.trim().toLowerCase();
    for (final environment in JoblensAppEnvironment.values) {
      if (environment.name == normalized) {
        return environment;
      }
    }
    return null;
  }
}

class AppRuntimeConfiguration {
  const AppRuntimeConfiguration({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.apiBaseUrlOverride,
    this.environment,
  });

  final JoblensAppEnvironment? environment;
  final String supabaseUrl;
  final String supabaseAnonKey;
  final String apiBaseUrlOverride;

  static Future<AppRuntimeConfiguration> load() async {
    final assetValues = await _tryLoadDotEnvAsset();
    return fromSources(
      compileTimeValues: _compileTimeValues(),
      assetValues: assetValues,
    );
  }

  static AppRuntimeConfiguration fromSources({
    Map<String, String> compileTimeValues = const {},
    Map<String, String> assetValues = const {},
  }) {
    final compileTimeEnvironment = _extractEnvironment(compileTimeValues);
    if (compileTimeEnvironment != null) {
      return _fromNamedEnvironment(
        environment: compileTimeEnvironment,
        values: compileTimeValues,
      );
    }

    final assetEnvironment = _extractEnvironment(assetValues);
    if (assetEnvironment != null) {
      return _fromNamedEnvironment(
        environment: assetEnvironment,
        values: assetValues,
      );
    }

    final supabaseUrl = _firstNonEmpty(
      _extractSupabaseUrl(compileTimeValues),
      _extractSupabaseUrl(assetValues),
    );
    final apiBaseUrlOverride = _firstNonEmpty(
      _extractApiBaseUrl(compileTimeValues),
      _extractApiBaseUrl(assetValues),
    );

    return AppRuntimeConfiguration(
      environment: _inferEnvironment(supabaseUrl, apiBaseUrlOverride),
      supabaseUrl: supabaseUrl,
      supabaseAnonKey: _firstNonEmpty(
        _extractSupabaseAnonKey(compileTimeValues),
        _extractSupabaseAnonKey(assetValues),
      ),
      apiBaseUrlOverride: apiBaseUrlOverride,
    );
  }

  bool get isConfigured =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  bool get isFullyConfigured => isConfigured && apiBaseUrl.trim().isNotEmpty;

  String get environmentName => environment?.name ?? 'custom';

  String get appAuthRedirectUri => _kAppAuthRedirectUri;

  String get apiBaseUrl => apiBaseUrlOverride.trim().isNotEmpty
      ? apiBaseUrlOverride.trim()
      : '${supabaseUrl.trim()}$_kDefaultApiBasePath';

  String get emailAuthRedirectUri {
    if (apiBaseUrl.trim().isNotEmpty) {
      return _appendPath(apiBaseUrl, 'auth/callback');
    }
    if (supabaseUrl.trim().isNotEmpty) {
      return _replacePath(supabaseUrl.trim(), _kDefaultEmailAuthCallbackPath);
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

  static Map<String, String> _compileTimeValues() {
    return {
      'JOBLENS_ENV': const String.fromEnvironment('JOBLENS_ENV'),
      'JOBLENS_APP_ENV': const String.fromEnvironment('JOBLENS_APP_ENV'),
      'SUPABASE_URL': const String.fromEnvironment('SUPABASE_URL'),
      'JOBLENS_SUPABASE_URL': const String.fromEnvironment(
        'JOBLENS_SUPABASE_URL',
      ),
      'SUPABASE_ANON_KEY': const String.fromEnvironment('SUPABASE_ANON_KEY'),
      'JOBLENS_SUPABASE_ANON_KEY': const String.fromEnvironment(
        'JOBLENS_SUPABASE_ANON_KEY',
      ),
      'API_BASE_URL': const String.fromEnvironment('API_BASE_URL'),
    };
  }

  static AppRuntimeConfiguration _fromNamedEnvironment({
    required JoblensAppEnvironment environment,
    required Map<String, String> values,
  }) {
    final resolvedSupabaseUrl = _firstNonEmpty(
      _extractSupabaseUrl(values),
      environment.supabaseUrl,
    );
    final resolvedApiBaseUrl = _firstNonEmpty(
      _extractApiBaseUrl(values),
      environment.apiBaseUrl,
    );

    if (!_urlsMatch(resolvedSupabaseUrl, environment.supabaseUrl)) {
      throw StateError(
        'JOBLENS_ENV=${environment.name} requires SUPABASE_URL=${environment.supabaseUrl}, '
        'but found $resolvedSupabaseUrl.',
      );
    }
    if (!_urlsMatch(resolvedApiBaseUrl, environment.apiBaseUrl)) {
      throw StateError(
        'JOBLENS_ENV=${environment.name} requires API_BASE_URL=${environment.apiBaseUrl}, '
        'but found $resolvedApiBaseUrl.',
      );
    }

    return AppRuntimeConfiguration(
      environment: environment,
      supabaseUrl: environment.supabaseUrl,
      supabaseAnonKey: _extractSupabaseAnonKey(values),
      apiBaseUrlOverride: environment.apiBaseUrl,
    );
  }

  static JoblensAppEnvironment? _extractEnvironment(
    Map<String, String> values,
  ) {
    return JoblensAppEnvironment.tryParse(
      _firstNonEmpty(
        values['JOBLENS_ENV'] ?? '',
        values['JOBLENS_APP_ENV'] ?? '',
      ),
    );
  }

  static JoblensAppEnvironment? _inferEnvironment(
    String supabaseUrl,
    String apiBaseUrl,
  ) {
    for (final environment in JoblensAppEnvironment.values) {
      final matchesSupabase =
          supabaseUrl.isNotEmpty &&
          _urlsMatch(supabaseUrl, environment.supabaseUrl);
      final matchesApi =
          apiBaseUrl.isNotEmpty &&
          _urlsMatch(apiBaseUrl, environment.apiBaseUrl);
      if (!matchesSupabase && !matchesApi) {
        continue;
      }
      if (supabaseUrl.isNotEmpty && !matchesSupabase) {
        continue;
      }
      if (apiBaseUrl.isNotEmpty && !matchesApi) {
        continue;
      }
      return environment;
    }
    return null;
  }

  static String _extractSupabaseUrl(Map<String, String> values) {
    return _normalizeUrl(
      _firstNonEmpty(
        values['SUPABASE_URL'] ?? '',
        values['JOBLENS_SUPABASE_URL'] ?? '',
      ),
    );
  }

  static String _extractSupabaseAnonKey(Map<String, String> values) {
    return _firstNonEmpty(
      values['SUPABASE_ANON_KEY'] ?? '',
      values['JOBLENS_SUPABASE_ANON_KEY'] ?? '',
    );
  }

  static String _extractApiBaseUrl(Map<String, String> values) {
    return _normalizeUrl(values['API_BASE_URL'] ?? '');
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

  static bool _urlsMatch(String value, String expected) {
    return _normalizeUrl(value) == _normalizeUrl(expected);
  }
}

String _firstNonEmpty(String primary, String fallback) {
  final primaryTrimmed = primary.trim();
  if (primaryTrimmed.isNotEmpty) {
    return primaryTrimmed;
  }
  return fallback.trim();
}

String _normalizeUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.endsWith('/')) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

String _appendPath(String baseUrl, String suffix) {
  final uri = Uri.parse(_normalizeUrl(baseUrl));
  final normalizedPath = uri.path.endsWith('/')
      ? '${uri.path}$suffix'
      : '${uri.path}/$suffix';
  return uri.replace(path: normalizedPath).toString();
}

String _replacePath(String baseUrl, String path) {
  final uri = Uri.parse(_normalizeUrl(baseUrl));
  return uri.replace(path: path).toString();
}
