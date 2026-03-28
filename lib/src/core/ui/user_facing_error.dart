String? userFacingStoreError(String? rawError) {
  if (rawError == null || rawError.trim().isEmpty) {
    return null;
  }

  final normalized = rawError.toLowerCase();

  if (normalized.contains('backend api client is not configured')) {
    return null;
  }

  if (normalized.contains('socketexception') ||
      normalized.contains('clientexception') ||
      normalized.contains('failed host lookup') ||
      normalized.contains('connection refused') ||
      normalized.contains('network is unreachable') ||
      normalized.contains('timed out')) {
    return 'Cloud sync is unavailable right now. Your photos remain on this device and can sync later.';
  }

  if (normalized.contains('unauthorized') ||
      normalized.contains('invalid supabase jwt') ||
      normalized.contains('auth_missing') ||
      normalized.contains('reauthentication_required')) {
    return 'Cloud sync needs you to sign in again.';
  }

  if (normalized.contains('project notes must be at most')) {
    return rawError;
  }

  if (normalized.contains('apiexception') ||
      normalized.contains('cloudsyncexception') ||
      normalized.contains('provider_error') ||
      normalized.contains('network_error') ||
      normalized.contains('http_')) {
    return 'Cloud sync hit a problem. Your photos remain on this device.';
  }

  return rawError;
}
