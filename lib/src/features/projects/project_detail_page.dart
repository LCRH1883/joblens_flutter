import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/models/project.dart';
import '../../core/ui/edge_swipe_back.dart';
import '../gallery/photo_viewer_page.dart';

class ProjectDetailPage extends ConsumerStatefulWidget {
  const ProjectDetailPage({super.key, required this.project});

  final Project project;

  @override
  ConsumerState<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends ConsumerState<ProjectDetailPage> {
  bool _handledMissingProject = false;

  final Set<String> _selectedAssetIds = <String>{};
  bool _selectionModeEnabled = false;
  bool _isDragSelecting = false;
  bool _dragSelectionAdds = true;
  String? _lastDraggedAssetId;

  bool get _isSelectionMode => _selectionModeEnabled;

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);
    final project = _currentProject(store);
    if (project == null) {
      _handleMissingProject(context);
      return const Scaffold(
        body: Center(child: Text('Project no longer available.')),
      );
    }

    final assets = store.assets
        .where((asset) => asset.projectId == project.id)
        .toList();
    _normalizeSelectionState(assets);

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
              : project.name,
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
                  tooltip: 'Edit notes',
                  onPressed: store.isBusy
                      ? null
                      : () => _openNotesEditor(context, store, project),
                  icon: Icon(
                    project.notes.trim().isEmpty
                        ? Icons.menu_book_outlined
                        : Icons.menu_book,
                  ),
                ),
              ],
      ),
      body: EdgeSwipeBack(
        child: assets.isEmpty
            ? const Center(child: Text('No photos in this project yet.'))
            : Column(
                children: [
                  if (store.isBusy)
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: LinearProgressIndicator(),
                    ),
                  if (store.lastError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            store.lastError!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: GridView.builder(
                      physics: _isDragSelecting
                          ? const NeverScrollableScrollPhysics()
                          : const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(8),
                      itemCount: assets.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                      itemBuilder: (context, index) {
                        final asset = assets[index];
                        return _ProjectAssetTile(
                          asset: asset,
                          store: store,
                          selected: _selectedAssetIds.contains(asset.id),
                          selectionMode: _isSelectionMode,
                          onTap: () => _onAssetTap(context, asset, assets),
                          onLongPressStart: () => _startDragSelection(asset.id),
                          onLongPressEnd: _stopDragSelection,
                          onDragHover: () => _dragSelectAsset(asset.id),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Project? _currentProject(JoblensStore store) {
    for (final project in store.projects) {
      if (project.id == widget.project.id) {
        return project;
      }
    }
    return null;
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
          builder: (context, setDialogState) {
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
                  setDialogState(() {
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

  void _handleMissingProject(BuildContext context) {
    if (_handledMissingProject) {
      return;
    }
    _handledMissingProject = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project no longer available.')),
      );
      Navigator.of(context).maybePop();
    });
  }

  Future<void> _openNotesEditor(
    BuildContext context,
    JoblensStore store,
    Project project,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final editedNotes = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _ProjectNotesEditorPage(initialNotes: project.notes),
      ),
    );
    if (!mounted) {
      return;
    }
    if (editedNotes == null) {
      return;
    }

    await store.updateProjectNotes(project.id, editedNotes);
    if (!mounted) {
      return;
    }
    if (store.lastError != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to save notes: ${store.lastError}')),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Notes saved.')));
  }
}

class _ProjectAssetTile extends StatelessWidget {
  const _ProjectAssetTile({
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
          _ProjectAssetThumbnail(asset: asset, store: store),
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

class _ProjectAssetThumbnail extends StatefulWidget {
  const _ProjectAssetThumbnail({required this.asset, required this.store});

  final PhotoAsset asset;
  final JoblensStore store;

  @override
  State<_ProjectAssetThumbnail> createState() => _ProjectAssetThumbnailState();
}

class _ProjectAssetThumbnailState extends State<_ProjectAssetThumbnail> {
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

class _ProjectNotesEditorPage extends StatefulWidget {
  const _ProjectNotesEditorPage({required this.initialNotes});

  final String initialNotes;

  @override
  State<_ProjectNotesEditorPage> createState() =>
      _ProjectNotesEditorPageState();
}

class _ProjectNotesEditorPageState extends State<_ProjectNotesEditorPage> {
  late final TextEditingController _controller;

  bool get _isOverLimit => _controller.text.length > kProjectNotesMaxLength;
  bool get _isDirty =>
      normalizeProjectNotesForSave(_controller.text) != widget.initialNotes;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNotes);
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit notes')),
      body: EdgeSwipeBack(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 8,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: 'Add notes for this library...',
                  border: const OutlineInputBorder(),
                  errorText: _isOverLimit
                      ? 'Notes must be at most $kProjectNotesMaxLength characters.'
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${_controller.text.length}/$kProjectNotesMaxLength',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _isDirty && !_isOverLimit
                        ? () {
                            Navigator.of(context).pop(
                              normalizeProjectNotesForSave(_controller.text),
                            );
                          }
                        : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }
}
