import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_runtime_configuration.dart';

final authConfigurationProvider = Provider<bool>((ref) => false);
final appRuntimeConfigurationProvider = Provider<AppRuntimeConfiguration>(
  (ref) => const AppRuntimeConfiguration(
    supabaseUrl: '',
    supabaseAnonKey: '',
    apiBaseUrlOverride: '',
  ),
);

final authStateStreamProvider = StreamProvider<AuthState?>((ref) {
  final isConfigured = ref.watch(authConfigurationProvider);
  if (!isConfigured) {
    return Stream<AuthState?>.value(null);
  }

  final auth = Supabase.instance.client.auth;
  return auth.onAuthStateChange;
});

final authSessionProvider = Provider<Session?>((ref) {
  return ref.watch(authStateStreamProvider).valueOrNull?.session;
});

final authUserProvider = Provider<User?>((ref) {
  return ref.watch(authSessionProvider)?.user;
});

String authEventFingerprint(AuthState? state) {
  final eventName = state?.event.name ?? 'none';
  final session = state?.session;
  final userId = session?.user.id.trim().isNotEmpty == true
      ? session!.user.id.trim()
      : 'none';
  final accessToken = session?.accessToken.trim() ?? '';
  final sessionId = accessToken.isEmpty
      ? ''
      : (extractAuthSessionId(accessToken) ?? '');
  return '$eventName|$userId|$sessionId|$accessToken';
}

String? extractAuthSessionId(String accessToken) {
  final parts = accessToken.split('.');
  if (parts.length < 2) {
    return null;
  }
  try {
    final normalized = base64Url.normalize(parts[1]);
    final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (payload is Map && payload['session_id'] is String) {
      return payload['session_id'] as String;
    }
  } catch (_) {
    // Ignore malformed access tokens and skip realtime subscription.
  }
  return null;
}
