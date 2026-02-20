import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cloud_adapter.dart';

extension HttpResponseX on http.Response {
  void ensureSuccess({String? context}) {
    if (statusCode >= 200 && statusCode < 300) {
      return;
    }

    final prefix = context == null ? '' : '$context: ';
    throw CloudSyncException('${prefix}HTTP $statusCode ${body.trim()}');
  }

  Map<String, dynamic> decodeJsonMap({String? context}) {
    ensureSuccess(context: context);
    if (body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    throw CloudSyncException('${context ?? 'decodeJsonMap'}: unexpected JSON');
  }
}

Future<void> ensureMultipartSuccess(
  http.StreamedResponse response, {
  String? context,
}) async {
  if (response.statusCode >= 200 && response.statusCode < 300) {
    return;
  }

  final body = await response.stream.bytesToString();
  final prefix = context == null ? '' : '$context: ';
  throw CloudSyncException(
    '${prefix}HTTP ${response.statusCode} ${body.trim()}',
  );
}
