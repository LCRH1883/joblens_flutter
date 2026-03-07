class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.rawBody,
  });

  factory ApiException.authMissing([String? message]) {
    return ApiException(
      code: 'auth_missing',
      message: message ?? 'Authentication is required to call the backend API.',
      statusCode: 401,
    );
  }

  final int? statusCode;
  final String code;
  final String message;
  final String? rawBody;

  bool get isAuthMissing => code == 'auth_missing';

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'ApiException$status: [$code] $message';
  }
}
