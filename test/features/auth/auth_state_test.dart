import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:joblens_flutter/src/features/auth/auth_state.dart';

void main() {
  test('authEventFingerprint is stable for identical auth states', () {
    final state = AuthState(
      AuthChangeEvent.initialSession,
      _session('user-1', sessionId: 'session-1'),
    );

    expect(authEventFingerprint(state), authEventFingerprint(state));
  });

  test('authEventFingerprint changes when the session token changes', () {
    final first = AuthState(
      AuthChangeEvent.initialSession,
      _session('user-1', sessionId: 'session-a'),
    );
    final second = AuthState(
      AuthChangeEvent.initialSession,
      _session('user-1', sessionId: 'session-b'),
    );

    expect(authEventFingerprint(first), isNot(authEventFingerprint(second)));
  });

  test('extractAuthSessionId returns the JWT session_id claim', () {
    final session = _session('user-1', sessionId: 'session-123');

    expect(extractAuthSessionId(session.accessToken), 'session-123');
  });
}

Session _session(String userId, {required String sessionId}) {
  final header = _encodeJson({'alg': 'HS256', 'typ': 'JWT'});
  final payload = _encodeJson({
    'sub': userId,
    'session_id': sessionId,
    'role': 'authenticated',
    'exp': 9999999999,
  });
  final accessToken = '$header.$payload.signature';

  return Session.fromJson({
    'access_token': accessToken,
    'token_type': 'bearer',
    'refresh_token': 'refresh-token-$sessionId',
    'expires_in': 3600,
    'user': {
      'id': userId,
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'aud': 'authenticated',
      'email': '$userId@example.com',
      'created_at': DateTime(2026, 4, 18).toIso8601String(),
    },
  })!;
}

String _encodeJson(Map<String, Object?> value) {
  return base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
}
