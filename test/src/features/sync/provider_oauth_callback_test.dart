import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/features/sync/provider_oauth_callback.dart';

void main() {
  test('parses Dropbox success callback query parameters', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'joblens://auth-callback?provider=dropbox&status=success&state=abc123',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.provider, CloudProviderType.dropbox);
    expect(callback.status, 'success');
    expect(callback.isSuccess, isTrue);
  });

  test('parses Dropbox error callback query parameters', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'joblens://auth-callback?provider=dropbox&status=error&code=access_denied&message=User%20cancelled',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.provider, CloudProviderType.dropbox);
    expect(callback.status, 'error');
    expect(callback.code, 'access_denied');
    expect(callback.message, 'User cancelled');
    expect(
      callback.userFacingMessage(),
      'Dropbox connection did not complete: User cancelled.',
    );
  });

  test('parses provider callback parameters from fragment', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'joblens://auth-callback#provider=dropbox&status=success&state=abc123',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.provider, CloudProviderType.dropbox);
    expect(callback.status, 'success');
  });

  test('parses HTTPS provider callback session result link', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'https://auth.joblens.app/mobile/provider-callback?sid=session-123&status=success&result=success',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.sessionId, 'session-123');
    expect(callback.status, 'success');
  });
}
