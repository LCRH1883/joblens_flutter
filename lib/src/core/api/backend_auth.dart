import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AccessTokenProvider {
  Future<String?> getAccessToken({bool forceRefresh = false});
}

class SupabaseAccessTokenProvider implements AccessTokenProvider {
  const SupabaseAccessTokenProvider();

  @override
  Future<String?> getAccessToken({bool forceRefresh = false}) async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    if (!forceRefresh) {
      final token = session?.accessToken;
      if (token != null && token.trim().isNotEmpty) {
        return token;
      }
    }

    try {
      final refreshed = await auth.refreshSession();
      final token =
          refreshed.session?.accessToken ?? auth.currentSession?.accessToken;
      if (token == null || token.trim().isEmpty) {
        return null;
      }
      return token;
    } catch (_) {
      return null;
    }
  }
}
