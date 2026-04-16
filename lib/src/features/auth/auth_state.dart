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
  final controller = StreamController<AuthState?>();
  controller.add(
    AuthState(AuthChangeEvent.initialSession, auth.currentSession),
  );

  final subscription = auth.onAuthStateChange.listen((state) {
    controller.add(state);
  });

  ref.onDispose(() async {
    await subscription.cancel();
    await controller.close();
  });

  return controller.stream;
});

final authSessionProvider = Provider<Session?>((ref) {
  return ref.watch(authStateStreamProvider).valueOrNull?.session;
});

final authUserProvider = Provider<User?>((ref) {
  return ref.watch(authSessionProvider)?.user;
});
