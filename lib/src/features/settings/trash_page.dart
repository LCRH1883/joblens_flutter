import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';

class TrashPage extends ConsumerWidget {
  const TrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final deletedAssets = store.deletedAssets.toList(growable: false)
      ..sort((a, b) {
        final aDeleted = a.deletedAt?.millisecondsSinceEpoch ?? 0;
        final bDeleted = b.deletedAt?.millisecondsSinceEpoch ?? 0;
        return bDeleted.compareTo(aDeleted);
      });
    final projectNames = {
      for (final project in store.projects) project.id: project.name,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Trash')),
      body: RefreshIndicator(
        onRefresh: store.runSyncNow,
        child: deletedAssets.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: const [
                  SizedBox(height: 72),
                  Icon(Icons.delete_outline_rounded, size: 52),
                  SizedBox(height: 16),
                  Text(
                    'Trash is empty',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Deleted photos stay here for 30 days before permanent removal.',
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: deletedAssets.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final asset = deletedAssets[index];
                  final projectName =
                      projectNames[asset.projectId] ?? 'Unknown project';
                  return _TrashAssetCard(
                    asset: asset,
                    projectName: projectName,
                    onRestore: () => _restoreAsset(context, ref, asset.id),
                    onPurge: () => _confirmPermanentDelete(
                      context,
                      ref,
                      asset.id,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _restoreAsset(
    BuildContext context,
    WidgetRef ref,
    String assetId,
  ) async {
    final store = ref.read(joblensStoreProvider);
    await store.restoreAsset(assetId);
    if (!context.mounted) {
      return;
    }
    final message = store.lastError;
    if (message != null && message.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Photo restored from Trash.')),
    );
  }

  Future<void> _confirmPermanentDelete(
    BuildContext context,
    WidgetRef ref,
    String assetId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete permanently?'),
          content: const Text(
            'This removes the photo from Joblens Trash and cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete now'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final store = ref.read(joblensStoreProvider);
    await store.purgeAssetPermanently(assetId);
    if (!context.mounted) {
      return;
    }
    final message = store.lastError;
    if (message != null && message.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Photo permanently deleted.')),
    );
  }
}

class _TrashAssetCard extends StatelessWidget {
  const _TrashAssetCard({
    required this.asset,
    required this.projectName,
    required this.onRestore,
    required this.onPurge,
  });

  final PhotoAsset asset;
  final String projectName;
  final Future<void> Function() onRestore;
  final Future<void> Function() onPurge;

  @override
  Widget build(BuildContext context) {
    final deletedAt = asset.deletedAt;
    final dueAt =
        asset.hardDeleteDueAt ??
        deletedAt?.add(const Duration(days: 30));
    final dateFormat = DateFormat('MMM d, y');
    final deletedLabel = deletedAt == null
        ? 'Deleted recently'
        : 'Deleted ${dateFormat.format(deletedAt)}';
    final daysRemaining = dueAt
        ?.difference(DateTime.now())
        .inDays
        .clamp(0, 36500);
    final dueLabel = dueAt == null
        ? 'Auto-delete date unavailable'
        : daysRemaining == 0
        ? 'Auto-delete today'
        : '$daysRemaining day${daysRemaining == 1 ? '' : 's'} left';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TrashThumbnail(asset: asset),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asset.filenameLabel,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(projectName),
                  const SizedBox(height: 4),
                  Text(
                    deletedLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dueLabel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await onRestore();
                        },
                        icon: const Icon(Icons.restore_rounded),
                        label: const Text('Restore'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await onPurge();
                        },
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Delete now'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrashThumbnail extends StatelessWidget {
  const _TrashThumbnail({required this.asset});

  final PhotoAsset asset;

  @override
  Widget build(BuildContext context) {
    final thumbPath = asset.thumbPath.trim();
    final localPath = asset.localPath.trim();
    final imagePath = thumbPath.isNotEmpty ? thumbPath : localPath;
    final file = imagePath.isEmpty ? null : File(imagePath);
    final imageProvider = file != null && file.existsSync()
        ? FileImage(file)
        : null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 84,
        height: 84,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: imageProvider == null
            ? const Icon(Icons.photo_outlined)
            : Image(
                image: imageProvider,
                fit: BoxFit.cover,
              ),
      ),
    );
  }
}

extension on PhotoAsset {
  String get filenameLabel {
    final localPath = this.localPath.trim();
    if (localPath.isNotEmpty) {
      return localPath.split(Platform.pathSeparator).last;
    }
    final uploadPath = this.uploadPath?.trim();
    if (uploadPath != null && uploadPath.isNotEmpty) {
      return uploadPath.split('/').last;
    }
    return 'Deleted photo';
  }
}
