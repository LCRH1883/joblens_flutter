import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../camera/camera_capture_page.dart';
import 'photo_viewer_page.dart';

class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends ConsumerState<GalleryPage> {
  final Set<String> _selectedAssetIds = <String>{};
  final Map<String, GlobalKey> _tileKeys = <String, GlobalKey>{};

  bool _isDragSelecting = false;
  bool _dragSelectionAdds = true;
  String? _lastDraggedAssetId;

  bool get _isSelectionMode => _selectedAssetIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);
    final assets = store.assets;
    _normalizeSelectionState(assets);

    final grouped = _groupByDay(assets);
    final allSelected =
        assets.isNotEmpty && _selectedAssetIds.length == assets.length;

    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                tooltip: 'Exit selection',
                onPressed: store.isBusy ? null : _clearSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(
          _isSelectionMode
              ? '${_selectedAssetIds.length} selected'
              : 'Joblens Gallery',
        ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: allSelected ? 'Clear selection' : 'Select all',
                  onPressed: store.isBusy
                      ? null
                      : () => _toggleSelectAll(assets),
                  icon: Icon(allSelected ? Icons.clear_all : Icons.select_all),
                ),
                IconButton(
                  tooltip: 'Move selected',
                  onPressed: store.isBusy || store.projects.isEmpty
                      ? null
                      : () => _showMoveDialog(context, store),
                  icon: const Icon(Icons.drive_file_move_outline),
                ),
                IconButton(
                  tooltip: 'Delete selected',
                  onPressed: store.isBusy
                      ? null
                      : () => _confirmDeleteSelected(context, store),
                  icon: const Icon(Icons.delete_outline),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Import photos',
                  onPressed: store.isBusy
                      ? null
                      : () => store.importFromPhoneGallery(),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
              ],
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CameraCapturePage(),
                  ),
                );
              },
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Capture'),
            ),
      body: _buildBody(context, store, grouped, assets),
    );
  }

  Widget _buildBody(
    BuildContext context,
    JoblensStore store,
    Map<String, List<PhotoAsset>> grouped,
    List<PhotoAsset> assets,
  ) {
    if (store.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (assets.isEmpty) {
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

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (event) => _handleDragSelection(event.position, assets),
      onPointerUp: (_) => _stopDragSelection(),
      onPointerCancel: (_) => _stopDragSelection(),
      child: RefreshIndicator(
        onRefresh: store.refresh,
        child: ListView(
          physics: _isDragSelecting
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
                  return _AssetTile(
                    key: _tileKeyFor(asset.id),
                    asset: asset,
                    selected: _selectedAssetIds.contains(asset.id),
                    selectionMode: _isSelectionMode,
                    onTap: () => _onAssetTap(context, asset, assets),
                    onLongPressStart: () => _startDragSelection(asset.id),
                    onLongPressEnd: _stopDragSelection,
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onAssetTap(
    BuildContext context,
    PhotoAsset asset,
    List<PhotoAsset> assets,
  ) {
    if (_isSelectionMode) {
      setState(() {
        _toggleSelection(asset.id);
      });
      return;
    }

    final initialIndex = assets.indexWhere((item) => item.id == asset.id);
    if (initialIndex < 0) {
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(
          paths: assets.map((item) => item.localPath).toList(growable: false),
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  void _toggleSelection(String assetId) {
    if (_selectedAssetIds.contains(assetId)) {
      _selectedAssetIds.remove(assetId);
    } else {
      _selectedAssetIds.add(assetId);
    }
  }

  void _toggleSelectAll(List<PhotoAsset> assets) {
    setState(() {
      if (_selectedAssetIds.length == assets.length) {
        _clearSelectionState();
        return;
      }
      _selectedAssetIds
        ..clear()
        ..addAll(assets.map((asset) => asset.id));
    });
  }

  void _startDragSelection(String assetId) {
    setState(() {
      if (_selectedAssetIds.contains(assetId)) {
        _dragSelectionAdds = false;
        _selectedAssetIds.remove(assetId);
      } else {
        _dragSelectionAdds = true;
        _selectedAssetIds.add(assetId);
      }
      _isDragSelecting = true;
      _lastDraggedAssetId = assetId;
    });
  }

  void _stopDragSelection() {
    if (!_isDragSelecting) {
      return;
    }

    setState(() {
      _isDragSelecting = false;
      _lastDraggedAssetId = null;
    });
  }

  void _handleDragSelection(Offset globalPosition, List<PhotoAsset> assets) {
    if (!_isDragSelecting) {
      return;
    }

    final hitAssetId = _assetIdAtPosition(globalPosition, assets);
    if (hitAssetId == null || hitAssetId == _lastDraggedAssetId) {
      return;
    }

    setState(() {
      if (_dragSelectionAdds) {
        _selectedAssetIds.add(hitAssetId);
      } else {
        _selectedAssetIds.remove(hitAssetId);
      }
      _lastDraggedAssetId = hitAssetId;

      if (_selectedAssetIds.isEmpty) {
        _isDragSelecting = false;
      }
    });
  }

  String? _assetIdAtPosition(Offset globalPosition, List<PhotoAsset> assets) {
    for (final asset in assets) {
      final key = _tileKeys[asset.id];
      final tileContext = key?.currentContext;
      if (tileContext == null) {
        continue;
      }

      final renderObject = tileContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) {
        continue;
      }

      final localPosition = renderObject.globalToLocal(globalPosition);
      final insideTile =
          localPosition.dx >= 0 &&
          localPosition.dy >= 0 &&
          localPosition.dx <= renderObject.size.width &&
          localPosition.dy <= renderObject.size.height;
      if (insideTile) {
        return asset.id;
      }
    }
    return null;
  }

  Future<void> _showMoveDialog(BuildContext context, JoblensStore store) async {
    if (_selectedAssetIds.isEmpty || store.projects.isEmpty) {
      return;
    }

    int selectedProject = store.projects.first.id;
    final selectedIds = _selectedAssetIds.toList(growable: false);

    final moved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Move ${selectedIds.length} photo(s) to project'),
              content: DropdownButton<int>(
                value: selectedProject,
                isExpanded: true,
                items: [
                  for (final project in store.projects)
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
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    await store.moveAssetsToProject(
                      selectedIds,
                      selectedProject,
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop(true);
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

    if (moved == true && mounted) {
      setState(_clearSelectionState);
    }
  }

  Future<void> _confirmDeleteSelected(
    BuildContext context,
    JoblensStore store,
  ) async {
    if (_selectedAssetIds.isEmpty) {
      return;
    }

    final selectedIds = _selectedAssetIds.toList(growable: false);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete ${selectedIds.length} photo(s)?'),
          content: const Text(
            'This removes the selected photos from Joblens library.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    await store.softDeleteAssets(selectedIds);
    if (!mounted) {
      return;
    }

    setState(_clearSelectionState);
  }

  void _clearSelection() {
    setState(_clearSelectionState);
  }

  void _clearSelectionState() {
    _selectedAssetIds.clear();
    _isDragSelecting = false;
    _lastDraggedAssetId = null;
  }

  void _normalizeSelectionState(List<PhotoAsset> assets) {
    final assetIds = assets.map((asset) => asset.id).toSet();
    _selectedAssetIds.removeWhere((assetId) => !assetIds.contains(assetId));
    _tileKeys.removeWhere((assetId, _) => !assetIds.contains(assetId));

    if (_selectedAssetIds.isEmpty) {
      _isDragSelecting = false;
      _lastDraggedAssetId = null;
    }
  }

  GlobalKey _tileKeyFor(String assetId) {
    return _tileKeys.putIfAbsent(assetId, () => GlobalKey());
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

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });

  final PhotoAsset asset;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (_) => onLongPressStart(),
      onLongPressEnd: (_) => onLongPressEnd(),
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
          if (selected)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.30),
              ),
            ),
          if (selectionMode || selected)
            Positioned(
              left: 4,
              top: 4,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.2),
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black.withValues(alpha: 0.30),
                ),
                child: selected
                    ? Icon(
                        Icons.check,
                        size: 14,
                        color: Theme.of(context).colorScheme.onPrimary,
                      )
                    : null,
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
}
