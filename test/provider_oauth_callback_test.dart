import 'package:flutter_test/flutter_test.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';
import 'package:joblens_flutter/src/features/sync/provider_oauth_callback.dart';

void main() {
  test('parses provider callback success from query params', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'joblens://auth-callback?provider=google_drive&status=success&accountIdentifier=user@example.com',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.provider.key, 'google_drive');
    expect(callback.isSuccess, isTrue);
    expect(
      callback.userFacingMessage(),
      'Google Drive connected as user@example.com.',
    );
  });

  test('parses provider callback error from fragment params', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse(
        'joblens://auth-callback#provider=google_drive&status=error&code=access_denied',
      ),
    );

    expect(callback, isNotNull);
    expect(callback!.isSuccess, isFalse);
    expect(
      callback.userFacingMessage(),
      'Google Drive connection did not complete: access denied.',
    );
  });

  test('ignores non-provider auth callback links', () {
    final callback = ProviderOAuthCallback.tryParse(
      Uri.parse('joblens://auth-callback#access_token=token&type=recovery'),
    );

    expect(callback, isNull);
  });
}
