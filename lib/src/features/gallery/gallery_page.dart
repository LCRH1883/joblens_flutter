import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/models/project.dart';
import '../camera/camera_capture_page.dart';
import 'photo_viewer_page.dart';

class GalleryPage extends ConsumerWidget {
  const GalleryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final assets = store.assets;
    final grouped = _groupByDay(assets);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Joblens Gallery'),
        actions: [
          IconButton(
            tooltip: 'Import photos',
            onPressed: store.isBusy
                ? null
                : () => store.importFromPhoneGallery(),
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CameraCapturePage()),
          );
        },
        icon: const Icon(Icons.photo_camera_outlined),
        label: const Text('Capture'),
      ),
      body: _buildBody(context, store, grouped),
    );
  }

  Widget _buildBody(
    BuildContext context,
    JoblensStore store,
    Map<String, List<PhotoAsset>> grouped,
  ) {
    if (store.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (store.assets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'No photos yet. Capture with Joblens or import from your phone gallery.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: store.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 100),
        children: [
          if (store.isBusy) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          ],
          if (store.lastError != null) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  store.lastError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          for (final entry in grouped.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                entry.key,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: entry.value.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 3,
                crossAxisSpacing: 3,
              ),
              itemBuilder: (context, index) {
                final asset = entry.value[index];
                return _AssetTile(asset: asset);
              },
            ),
          ],
        ],
      ),
    );
  }

  Map<String, List<PhotoAsset>> _groupByDay(List<PhotoAsset> assets) {
    final map = <String, List<PhotoAsset>>{};
    for (final asset in assets) {
      map.putIfAbsent(asset.dayLabel, () => []);
      map[asset.dayLabel]!.add(asset);
    }
    return map;
  }
}

class _AssetTile extends ConsumerWidget {
  const _AssetTile({required this.asset});

  final PhotoAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PhotoViewerPage(path: asset.localPath),
          ),
        );
      },
      onLongPress: () => _showActions(context, store),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(asset.thumbPath),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: Icon(
              asset.sourceType == AssetSourceType.captured
                  ? Icons.photo_camera_outlined
                  : Icons.file_download_done_outlined,
              size: 14,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showActions(BuildContext context, JoblensStore store) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('Move to project'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _showMoveDialog(context, store, store.projects);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete from Joblens'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await store.softDeleteAsset(asset.id);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showMoveDialog(
    BuildContext context,
    JoblensStore store,
    List<Project> projects,
  ) async {
    if (projects.isEmpty) {
      return;
    }

    int selectedProject = projects.first.id;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Move to project'),
              content: DropdownButton<int>(
                value: selectedProject,
                isExpanded: true,
                items: [
                  for (final project in projects)
                    DropdownMenuItem(
                      value: project.id,
                      child: Text(project.name),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    selectedProject = value;
                  });
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    await store.moveAssetToProject(asset.id, selectedProject);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  child: const Text('Move'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
