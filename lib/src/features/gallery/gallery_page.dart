import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/ui/user_facing_error.dart';
import '../camera/camera_capture_page.dart';
import 'photo_viewer_page.dart';

class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends ConsumerState<GalleryPage> {
  final Set<String> _selectedAssetIds = <String>{};
  bool _selectionModeEnabled = false;

  bool _isDragSelecting = false;
  bool _dragSelectionAdds = true;
  String? _lastDraggedAssetId;

  bool get _isSelectionMode => _selectionModeEnabled;

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
                  onPressed:
                      store.isBusy ||
                          store.projects.isEmpty ||
                          _selectedAssetIds.isEmpty
                      ? null
                      : () => _showMoveDialog(context, store),
                  icon: const Icon(Icons.drive_file_move_outline),
                ),
                IconButton(
                  tooltip: 'Delete selected',
                  onPressed: store.isBusy || _selectedAssetIds.isEmpty
                      ? null
                      : () => _confirmDeleteSelected(context, store),
                  icon: const Icon(Icons.delete_outline),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Select photos',
                  onPressed: store.isBusy || assets.isEmpty
                      ? null
                      : _enableSelectionMode,
                  icon: const Icon(Icons.checklist_outlined),
                ),
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

    return RefreshIndicator(
      onRefresh: store.refresh,
      child: CustomScrollView(
        physics: _isDragSelecting
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverPadding(padding: EdgeInsets.only(top: 12)),
          if (store.isBusy)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: LinearProgressIndicator(),
              ),
            ),
          if (userFacingStoreError(store.lastError) case final error?)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          for (final entry in grouped.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Text(
                  entry.key,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final asset = entry.value[index];
                  return _AssetTile(
                    asset: asset,
                    store: store,
                    selected: _selectedAssetIds.contains(asset.id),
                    selectionMode: _isSelectionMode,
                    onTap: () => _onAssetTap(context, asset, assets),
                    onLongPressStart: () => _startDragSelection(asset.id),
                    onLongPressEnd: _stopDragSelection,
                    onDragHover: () => _dragSelectAsset(asset.id),
                  );
                }, childCount: entry.value.length),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
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
        builder: (_) =>
            PhotoViewerPage(assets: assets, initialIndex: initialIndex),
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
        _selectedAssetIds.clear();
        return;
      }
      _selectedAssetIds
        ..clear()
        ..addAll(assets.map((asset) => asset.id));
    });
  }

  void _startDragSelection(String assetId) {
    setState(() {
      _selectionModeEnabled = true;
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

  void _dragSelectAsset(String assetId) {
    if (!_isDragSelecting) {
      return;
    }

    if (assetId == _lastDraggedAssetId) {
      return;
    }

    setState(() {
      if (_dragSelectionAdds) {
        _selectedAssetIds.add(assetId);
      } else {
        _selectedAssetIds.remove(assetId);
      }
      _lastDraggedAssetId = assetId;

      if (_selectedAssetIds.isEmpty) {
        _isDragSelecting = false;
      }
    });
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
      setState(_exitSelectionModeState);
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

    setState(_exitSelectionModeState);
  }

  void _clearSelection() {
    setState(_exitSelectionModeState);
  }

  void _enableSelectionMode() {
    setState(() {
      _selectionModeEnabled = true;
    });
  }

  void _clearSelectionState() {
    _selectedAssetIds.clear();
    _isDragSelecting = false;
    _lastDraggedAssetId = null;
  }

  void _exitSelectionModeState() {
    _selectionModeEnabled = false;
    _clearSelectionState();
  }

  void _normalizeSelectionState(List<PhotoAsset> assets) {
    final assetIds = assets.map((asset) => asset.id).toSet();
    _selectedAssetIds.removeWhere((assetId) => !assetIds.contains(assetId));

    if (assets.isEmpty) {
      _exitSelectionModeState();
      return;
    }

    if (_selectedAssetIds.isEmpty) {
      _isDragSelecting = false;
      _lastDraggedAssetId = null;
    }
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
    required this.asset,
    required this.store,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onDragHover,
  });

  final PhotoAsset asset;
  final JoblensStore store;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onDragHover;

  @override
  Widget build(BuildContext context) {
    final tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AssetThumbnail(asset: asset, store: store),
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

    return DragTarget<String>(
      onWillAcceptWithDetails: (_) {
        onDragHover();
        return false;
      },
      builder: (context, candidateData, rejectedData) {
        return LongPressDraggable<String>(
          data: asset.id,
          maxSimultaneousDrags: 1,
          hapticFeedbackOnStart: true,
          ignoringFeedbackPointer: true,
          feedback: const SizedBox(width: 1, height: 1),
          onDragStarted: onLongPressStart,
          onDragEnd: (_) => onLongPressEnd(),
          child: tile,
        );
      },
    );
  }
}

class _AssetThumbnail extends StatefulWidget {
  const _AssetThumbnail({required this.asset, required this.store});

  final PhotoAsset asset;
  final JoblensStore store;

  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  bool _forceRefresh = false;

  @override
  Widget build(BuildContext context) {
    final thumbPath = widget.asset.thumbPath;
    if (thumbPath.isNotEmpty && File(thumbPath).existsSync()) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _placeholder(context),
      );
    }

    return FutureBuilder<String?>(
      future: widget.store.resolveThumbnailUrl(
        widget.asset,
        forceRefresh: _forceRefresh,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _placeholder(context, loading: true);
        }
        final url = snapshot.data;
        if (url == null || url.isEmpty) {
          return _placeholder(context);
        }
        return Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            if (!_forceRefresh) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) {
                  return;
                }
                setState(() {
                  _forceRefresh = true;
                });
              });
            }
            return _placeholder(context);
          },
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.broken_image_outlined),
    );
  }
}
