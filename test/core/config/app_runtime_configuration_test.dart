import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/config/app_runtime_configuration.dart';

void main() {
  test('resolves dev contract from explicit environment selection', () {
    final config = AppRuntimeConfiguration.fromSources(
      compileTimeValues: {
        'JOBLENS_ENV': 'dev',
        'SUPABASE_ANON_KEY': 'dev-anon-key',
      },
    );

    expect(config.environment, JoblensAppEnvironment.dev);
    expect(config.supabaseUrl, 'https://dev.joblens.xyz');
    expect(config.apiBaseUrl, 'https://dev.joblens.xyz/functions/v1/api/v1');
    expect(
      config.emailAuthRedirectUri,
      'https://dev.joblens.xyz/functions/v1/api/v1/auth/callback',
    );
    expect(config.appAuthRedirectUri, 'joblens://auth-callback');
  });

  test('prefers compile-time environment over bundled asset fallback', () {
    final config = AppRuntimeConfiguration.fromSources(
      compileTimeValues: {
        'JOBLENS_ENV': 'prod',
        'SUPABASE_ANON_KEY': 'prod-anon-key',
      },
      assetValues: {
        'JOBLENS_ENV': 'dev',
        'SUPABASE_ANON_KEY': 'dev-anon-key',
        'SUPABASE_URL': 'https://dev.joblens.xyz',
        'API_BASE_URL': 'https://dev.joblens.xyz/functions/v1/api/v1',
      },
    );

    expect(config.environment, JoblensAppEnvironment.prod);
    expect(config.supabaseUrl, 'https://api.joblens.xyz');
    expect(config.apiBaseUrl, 'https://api.joblens.xyz/functions/v1/api/v1');
    expect(config.supabaseAnonKey, 'prod-anon-key');
  });

  test('rejects mismatched URLs for an explicit named environment', () {
    expect(
      () => AppRuntimeConfiguration.fromSources(
        compileTimeValues: {
          'JOBLENS_ENV': 'prod',
          'SUPABASE_URL': 'https://dev.joblens.xyz',
          'SUPABASE_ANON_KEY': 'prod-anon-key',
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('bundled asset environment works for dev fallback launches', () {
    final config = AppRuntimeConfiguration.fromSources(
      assetValues: {'JOBLENS_ENV': 'dev', 'SUPABASE_ANON_KEY': 'dev-anon-key'},
    );

    expect(config.environment, JoblensAppEnvironment.dev);
    expect(config.supabaseUrl, 'https://dev.joblens.xyz');
    expect(config.apiBaseUrl, 'https://dev.joblens.xyz/functions/v1/api/v1');
  });

  test('legacy manual mode still derives api base url from supabase url', () {
    final config = AppRuntimeConfiguration.fromSources(
      compileTimeValues: {
        'SUPABASE_URL': 'https://api.joblens.xyz',
        'SUPABASE_ANON_KEY': 'prod-anon-key',
      },
    );

    expect(config.environment, JoblensAppEnvironment.prod);
    expect(config.apiBaseUrl, 'https://api.joblens.xyz/functions/v1/api/v1');
    expect(
      config.emailAuthRedirectUri,
      'https://api.joblens.xyz/functions/v1/api/v1/auth/callback',
    );
  });
}
