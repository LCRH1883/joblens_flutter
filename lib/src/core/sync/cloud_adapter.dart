import '../models/cloud_provider.dart';
import '../models/photo_asset.dart';
import '../models/project.dart';

abstract class CloudAdapter {
  CloudProviderType get provider;

  Future<void> authenticate();

  Future<String> ensureProjectFolder(Project project);

  Future<void> uploadFile({
    required PhotoAsset asset,
    required Project project,
  });
}

class CloudSyncException implements Exception {
  const CloudSyncException(this.message);

  final String message;

  @override
  String toString() => 'CloudSyncException: $message';
}
