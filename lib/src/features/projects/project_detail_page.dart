import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/models/project.dart';
import '../../core/ui/asset_sync_badge.dart';
import '../../core/ui/edge_swipe_back.dart';
import '../../core/ui/user_facing_error.dart';
import '../gallery/photo_viewer_page.dart';

enum _AssetSortOrder { newestFirst, oldestFirst }

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
  _AssetSortOrder _sortOrder = _AssetSortOrder.newestFirst;

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

    var assets = store.assets
        .where((asset) => asset.projectId == project.id)
        .toList();
    assets.sort(
      (a, b) => _sortOrder == _AssetSortOrder.newestFirst
          ? b.createdAt.compareTo(a.createdAt)
          : a.createdAt.compareTo(b.createdAt),
    );
    _normalizeSelectionState(assets);

    final allSelected =
        assets.isNotEmpty && _selectedAssetIds.length == assets.length;

    return Scaffold(
      appBar: _isSelectionMode
          ? _buildSelectionAppBar(context, store, assets, allSelected)
          : _buildNormalAppBar(context, store, project, assets),
      body: EdgeSwipeBack(
        child: assets.isEmpty
            ? const Center(child: Text('No photos in this project yet.'))
            : Column(
                children: [
                  if (!_isSelectionMode)
                    _SortInfoBar(
                      assetCount: assets.length,
                      sortOrder: _sortOrder,
                      onSortChanged: (order) =>
                          setState(() => _sortOrder = order),
                    ),
                  if (store.isBusy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: LinearProgressIndicator(),
                    ),
                  if (userFacingStoreError(store.lastError) case final error?)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            error,
                            style: TextStyle(
                              color:
                                  Theme.of(context).colorScheme.onErrorContainer,
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
                      padding: const EdgeInsets.all(3),
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
      bottomNavigationBar: _isSelectionMode
          ? _SelectionActionBar(
              hasSelection: _selectedAssetIds.isNotEmpty,
              hasProjects: store.projects.isNotEmpty,
              busy: store.isBusy,
              onMove: () => _showMoveDialog(context, store),
              onArchive: () =>
                  _archiveSelectedToCloudOnly(context, store, assets),
              onDownload: () =>
                  _downloadSelectedToJoblens(context, store, assets),
              onDelete: () => _confirmDeleteSelected(context, store),
            )
          : null,
    );
  }

  AppBar _buildNormalAppBar(
    BuildContext context,
    JoblensStore store,
    Project project,
    List<PhotoAsset> assets,
  ) {
    return AppBar(
      title: Text(project.name),
      actions: [
        IconButton(
          tooltip: 'Select photos',
          onPressed: store.isBusy || assets.isEmpty ? null : _enableSelectionMode,
          icon: const Icon(Icons.checklist_outlined),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More options',
          onSelected: (value) => _handleProjectMenuAction(
            context,
            store,
            project,
            assets,
            value,
          ),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'notes',
              child: _MenuRow(
                icon: project.notes.trim().isEmpty
                    ? Icons.menu_book_outlined
                    : Icons.menu_book,
                label: 'Edit notes',
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'archive',
              enabled: assets.isNotEmpty && !store.isBusy,
              child: const _MenuRow(
                icon: Icons.archive_outlined,
                label: 'Archive all photos',
              ),
            ),
            PopupMenuItem(
              value: 'download',
              enabled: assets.isNotEmpty && !store.isBusy,
              child: const _MenuRow(
                icon: Icons.download_outlined,
                label: 'Download missing photos',
              ),
            ),
            PopupMenuItem(
              value: 'rescan',
              enabled: !(project.remoteProjectId?.trim().isEmpty ?? true) &&
                  !store.isBusy,
              child: const _MenuRow(
                icon: Icons.travel_explore_outlined,
                label: 'Rescan cloud',
              ),
            ),
          ],
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar(
    BuildContext context,
    JoblensStore store,
    List<PhotoAsset> assets,
    bool allSelected,
  ) {
    return AppBar(
      leading: IconButton(
        tooltip: 'Exit selection',
        onPressed: store.isBusy ? null : _clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('${_selectedAssetIds.length} selected'),
      actions: [
        IconButton(
          tooltip: allSelected ? 'Clear selection' : 'Select all',
          onPressed: store.isBusy ? null : () => _toggleSelectAll(assets),
          icon: Icon(allSelected ? Icons.clear_all : Icons.select_all),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More',
          onSelected: (value) {
            if (value == 'copy_phone') {
              _copySelectedToPhoneGallery(context, store, assets);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'copy_phone',
              enabled: _selectedAssetIds.isNotEmpty && !store.isBusy,
              child: const _MenuRow(
                icon: Icons.add_to_photos_outlined,
                label: 'Copy to phone gallery',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _handleProjectMenuAction(
    BuildContext context,
    JoblensStore store,
    Project project,
    List<PhotoAsset> assets,
    String value,
  ) async {
    switch (value) {
      case 'notes':
        await _openNotesEditor(context, store, project);
      case 'archive':
        await _archiveProjectToCloudOnly(context, store, project);
      case 'download':
        await _downloadProjectToJoblens(context, store, project);
      case 'rescan':
        await _reconcileProject(context, store, project);
    }
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
          title: Text('Move ${selectedIds.length} photo(s) to Trash?'),
          content: const Text(
            'The selected photos will move to Trash and stay there for 30 days before permanent removal.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Move to Trash'),
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

  Future<void> _copySelectedToPhoneGallery(
    BuildContext context,
    JoblensStore store,
    List<PhotoAsset> assets,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final selectedAssets = assets
        .where((asset) => _selectedAssetIds.contains(asset.id))
        .toList(growable: false);
    if (selectedAssets.isEmpty) {
      return;
    }

    final result = await store.copyAssetsToPhoneStorage(selectedAssets);
    if (!mounted) {
      return;
    }

    final copied = result.copiedCount;
    final skipped = result.skippedCount;
    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          skipped > 0
              ? 'Copied $copied photo(s) to phone gallery. Skipped $skipped already on phone storage.'
              : 'Copied $copied photo(s) to phone gallery.',
        ),
      ),
    );
  }

  Future<void> _downloadSelectedToJoblens(
    BuildContext context,
    JoblensStore store,
    List<PhotoAsset> assets,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final selectedAssets = assets
        .where((asset) => _selectedAssetIds.contains(asset.id))
        .toList(growable: false);
    if (selectedAssets.isEmpty) {
      return;
    }

    final result = await store.downloadAssetsToDevice(selectedAssets);
    if (!mounted) {
      return;
    }

    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }

    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _archiveSelectedToCloudOnly(
    BuildContext context,
    JoblensStore store,
    List<PhotoAsset> assets,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final selectedAssets = assets
        .where((asset) => _selectedAssetIds.contains(asset.id))
        .toList(growable: false);
    if (selectedAssets.isEmpty) {
      return;
    }

    final result = await store.archiveAssetsToCloudOnly(selectedAssets);
    if (!mounted) {
      return;
    }

    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }

    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _downloadProjectToJoblens(
    BuildContext context,
    JoblensStore store,
    Project project,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await store.downloadMissingProjectAssets(project.id);
    if (!mounted) {
      return;
    }

    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }

    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _archiveProjectToCloudOnly(
    BuildContext context,
    JoblensStore store,
    Project project,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await store.archiveProjectAssets(project.id);
    if (!mounted) {
      return;
    }

    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }

    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _reconcileProject(
    BuildContext context,
    JoblensStore store,
    Project project,
  ) async {
    final scheduled = await store.reconcileProject(project);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          scheduled
              ? 'Requested a cloud rescan for ${project.name}.'
              : '${project.name} is not synced to the cloud yet.',
        ),
      ),
    );
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
    if (userFacingStoreError(store.lastError) case final error?) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to save notes: $error')),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Notes saved.')));
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

class _SortInfoBar extends StatelessWidget {
  const _SortInfoBar({
    required this.assetCount,
    required this.sortOrder,
    required this.onSortChanged,
  });

  final int assetCount;
  final _AssetSortOrder sortOrder;
  final ValueChanged<_AssetSortOrder> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Row(
        children: [
          Text(
            '$assetCount photo${assetCount == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          PopupMenuButton<_AssetSortOrder>(
            initialValue: sortOrder,
            onSelected: onSortChanged,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.sort_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    sortOrder == _AssetSortOrder.newestFirst
                        ? 'Newest'
                        : 'Oldest',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _AssetSortOrder.newestFirst,
                child: Text('Newest first'),
              ),
              PopupMenuItem(
                value: _AssetSortOrder.oldestFirst,
                child: Text('Oldest first'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.hasSelection,
    required this.hasProjects,
    required this.busy,
    required this.onMove,
    required this.onArchive,
    required this.onDownload,
    required this.onDelete,
  });

  final bool hasSelection;
  final bool hasProjects;
  final bool busy;
  final VoidCallback onMove;
  final VoidCallback onArchive;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final canAct = hasSelection && !busy;
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.drive_file_move_outline,
                    label: 'Move',
                    onTap: canAct && hasProjects ? onMove : null,
                  ),
                  _ActionButton(
                    icon: Icons.archive_outlined,
                    label: 'Archive',
                    onTap: canAct ? onArchive : null,
                  ),
                  _ActionButton(
                    icon: Icons.download_outlined,
                    label: 'Download',
                    onTap: canAct ? onDownload : null,
                  ),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    label: 'Delete',
                    activeColor: Theme.of(context).colorScheme.error,
                    onTap: canAct ? onDelete : null,
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    this.activeColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? activeColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    final resolvedActive =
        activeColor ?? Theme.of(context).colorScheme.onSurface;
    final color = isEnabled
        ? resolvedActive
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
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
          Positioned(
            left: 4,
            bottom: 4,
            child: AssetSyncBadge(
              status: store.assetSyncStatusFor(asset.id),
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
  bool _localThumbFailed = false;

  @override
  void didUpdateWidget(covariant _ProjectAssetThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.thumbPath != widget.asset.thumbPath) {
      _localThumbFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbPath = widget.asset.thumbPath;
    if (thumbPath.isNotEmpty && !_localThumbFailed) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) {
          if (!_localThumbFailed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }
              setState(() {
                _localThumbFailed = true;
              });
            });
          }
          return _placeholder(context, loading: true);
        },
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
