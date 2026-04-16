import 'package:flutter_test/flutter_test.dart';

import 'package:joblens_flutter/src/core/api/backend_api_models.dart';
import 'package:joblens_flutter/src/core/models/cloud_provider.dart';

void main() {
  test('parses bulk-check response with duplicate and missing entries', () {
    final response = BulkCheckAssetsResponse.fromMap({
      'projectId': 'project-1',
      'duplicateCount': 1,
      'missingCount': 1,
      'results': [
        {
          'deviceAssetId': 'local-1',
          'sha256': 'a' * 64,
          'status': 'duplicate',
          'assetId': 'remote-1',
        },
        {
          'deviceAssetId': 'local-2',
          'sha256': 'b' * 64,
          'status': 'missing',
          'assetId': null,
        },
      ],
    });

    expect(response.projectId, 'project-1');
    expect(response.duplicateCount, 1);
    expect(response.missingCount, 1);
    expect(response.results, hasLength(2));
    expect(response.results.first.isDuplicate, isTrue);
    expect(response.results.first.assetId, 'remote-1');
    expect(response.results.last.isMissing, isTrue);
  });

  test('parses prepare-upload duplicate and upload_required variants', () {
    final duplicate = PrepareAssetUploadResponse.fromMap({
      'status': 'duplicate',
      'assetId': 'asset-dup',
      'uploadSessionId': 'session-1',
    });
    expect(duplicate.isDuplicate, isTrue);
    expect(duplicate.assetId, 'asset-dup');

    final uploadRequired = PrepareAssetUploadResponse.fromMap({
      'status': 'upload_required',
      'provider': 'google_drive',
      'uploadSessionId': 'session-2',
      'remotePath': 'Joblens/Library/file.jpg',
      'remoteFileId': 'provider-file-1',
      'upload': {
        'strategy': 'single_put',
        'url': 'https://upload.example/signed',
        'method': 'PUT',
        'headers': {'x-upload': '1'},
      },
    });
    expect(uploadRequired.isUploadRequired, isTrue);
    expect(uploadRequired.provider, CloudProviderType.googleDrive);
    expect(uploadRequired.remotePath, 'Joblens/Library/file.jpg');
    expect(uploadRequired.remoteFileId, 'provider-file-1');
    expect(uploadRequired.instruction?.url, 'https://upload.example/signed');
    expect(uploadRequired.uploadSessionId, 'session-2');
  });

  test('parses commit response variants', () {
    final committed = CommitAssetResponse.fromMap({
      'asset': {'id': 'asset-new'},
      'duplicate': false,
      'committed': true,
      'idempotentReplay': false,
    });
    expect(committed.assetId, 'asset-new');
    expect(committed.committed, isTrue);
    expect(committed.duplicate, isFalse);

    final duplicate = CommitAssetResponse.fromMap({
      'assetId': 'asset-existing',
      'duplicate': true,
      'committed': false,
    });
    expect(duplicate.assetId, 'asset-existing');
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.committed, isFalse);

    final replay = CommitAssetResponse.fromMap({
      'asset': {'id': 'asset-replay'},
      'assetId': 'asset-replay',
      'duplicate': true,
      'committed': true,
      'idempotentReplay': true,
    });
    expect(replay.assetId, 'asset-replay');
    expect(replay.idempotentReplay, isTrue);
    expect(replay.committed, isTrue);
  });

  test('parses backend asset cloud availability explicitly', () {
    final asset = BackendAssetRecord.fromMap({
      'assetId': 'asset-1',
      'sha256': 'a' * 64,
      'provider': 'google_drive',
      'remoteFileId': 'provider-file-1',
      'remotePath': 'Joblens/Inbox/file.jpg',
      'storageState': 'local_and_cloud',
      'cloudAvailable': false,
    });

    expect(asset.assetId, 'asset-1');
    expect(asset.provider, CloudProviderType.googleDrive);
    expect(asset.cloudAvailable, isFalse);
  });
}
