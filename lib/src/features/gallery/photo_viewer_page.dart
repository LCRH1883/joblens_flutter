import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/ui/edge_swipe_back.dart';

class PhotoViewerPage extends ConsumerStatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.assets,
    required this.initialIndex,
  }) : assert(assets.length > 0),
       assert(initialIndex >= 0),
       assert(initialIndex < assets.length);

  final List<PhotoAsset> assets;
  final int initialIndex;

  @override
  ConsumerState<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends ConsumerState<PhotoViewerPage> {
  final Map<int, TransformationController> _controllers =
      <int, TransformationController>{};
  late final PageController _pageController;
  late int _currentIndex;
  bool _isCurrentZoomed = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);
    final currentAsset = _currentAsset(store);
    final canDownloadCurrent = store.canDownloadAsset(currentAsset);
    final canArchiveCurrent = store.canArchiveAsset(currentAsset);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${_currentIndex + 1} / ${widget.assets.length}'),
        actions: [
          if (canDownloadCurrent)
            IconButton(
              tooltip: 'Download to device',
              onPressed: store.isBusy
                  ? null
                  : () => _downloadCurrentAsset(context, store, currentAsset),
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      ),
      body: EdgeSwipeBack(
        child: PageView.builder(
          controller: _pageController,
          physics: _isCurrentZoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.assets.length,
          onPageChanged: (index) {
            setState(() {
              _currentIndex = index;
              _isCurrentZoomed = _isZoomed(index);
            });
          },
          itemBuilder: (context, index) {
            final transformController = _controllerFor(index);
            final asset = _assetAt(store, index);
            return Center(
              child: InteractiveViewer(
                transformationController: transformController,
                minScale: 1,
                maxScale: 4,
                onInteractionUpdate: (_) => _syncZoomState(),
                onInteractionEnd: (_) => _syncZoomState(),
                child: _ViewerMedia(asset: asset),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: _PhotoActionBar(
        canArchive: canArchiveCurrent,
        hasProjects: store.projects.isNotEmpty,
        busy: store.isBusy,
        onArchive: () => _archiveCurrentAsset(context, store, currentAsset),
        onMove: () => _moveCurrentAsset(context, store, currentAsset),
        onDelete: () => _confirmDeleteCurrent(context, store, currentAsset),
      ),
    );
  }

  TransformationController _controllerFor(int index) {
    return _controllers.putIfAbsent(index, TransformationController.new);
  }

  bool _isZoomed(int index) {
    final controller = _controllers[index];
    if (controller == null) {
      return false;
    }

    final matrix = controller.value.storage;
    const epsilon = 0.01;
    final scaleX = matrix[0];
    final scaleY = matrix[5];
    return (scaleX - 1).abs() > epsilon || (scaleY - 1).abs() > epsilon;
  }

  void _syncZoomState() {
    final zoomed = _isZoomed(_currentIndex);
    if (zoomed == _isCurrentZoomed) {
      return;
    }

    setState(() {
      _isCurrentZoomed = zoomed;
    });
  }

  PhotoAsset _assetAt(JoblensStore store, int index) {
    final fallback = widget.assets[index];
    return store.assetById(fallback.id) ?? fallback;
  }

  PhotoAsset _currentAsset(JoblensStore store) => _assetAt(store, _currentIndex);

  Future<void> _downloadCurrentAsset(
    BuildContext context,
    JoblensStore store,
    PhotoAsset asset,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await store.downloadAssetsToDevice([asset]);
    if (!mounted) {
      return;
    }
    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _archiveCurrentAsset(
    BuildContext context,
    JoblensStore store,
    PhotoAsset asset,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await store.archiveAssetsToCloudOnly([asset]);
    if (!mounted) {
      return;
    }
    if (store.lastError != null) {
      messenger.showSnackBar(SnackBar(content: Text(store.lastError!)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(result.summaryMessage())));
  }

  Future<void> _moveCurrentAsset(
    BuildContext context,
    JoblensStore store,
    PhotoAsset asset,
  ) async {
    if (store.projects.isEmpty) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    int selectedProjectId = store.projects.first.id;

    final moved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Move to project'),
              content: DropdownButton<int>(
                value: selectedProjectId,
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
                  setDialogState(() => selectedProjectId = value);
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
                      [asset.id],
                      selectedProjectId,
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
      messenger.showSnackBar(
        const SnackBar(content: Text('Photo moved to project.')),
      );
    }
  }

  Future<void> _confirmDeleteCurrent(
    BuildContext context,
    JoblensStore store,
    PhotoAsset asset,
  ) async {
    final navigator = Navigator.of(context);
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Move to Trash?'),
          content: const Text(
            'This photo will move to Trash and stay there for 30 days before permanent removal.',
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

    await store.softDeleteAsset(asset.id);
    if (!mounted) {
      return;
    }

    navigator.pop();
  }
}

class _PhotoActionBar extends StatelessWidget {
  const _PhotoActionBar({
    required this.canArchive,
    required this.hasProjects,
    required this.busy,
    required this.onArchive,
    required this.onMove,
    required this.onDelete,
  });

  final bool canArchive;
  final bool hasProjects;
  final bool busy;
  final VoidCallback onArchive;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(color: Colors.white12, height: 1, thickness: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(
                    icon: Icons.archive_outlined,
                    label: 'Archive',
                    onTap: busy || !canArchive ? null : onArchive,
                  ),
                  _ActionButton(
                    icon: Icons.drive_file_move_outline,
                    label: 'Move',
                    onTap: busy || !hasProjects ? null : onMove,
                  ),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    label: 'Delete',
                    activeColor: Colors.red[300]!,
                    onTap: busy ? null : onDelete,
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
    this.activeColor = Colors.white,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color activeColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    final color = isEnabled
        ? activeColor
        : Colors.white.withValues(alpha: 0.3);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 5),
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

class _ViewerMedia extends ConsumerStatefulWidget {
  const _ViewerMedia({required this.asset});

  final PhotoAsset asset;

  @override
  ConsumerState<_ViewerMedia> createState() => _ViewerMediaState();
}

class _ViewerMediaState extends ConsumerState<_ViewerMedia> {
  bool _forceRefresh = false;
  bool _localFileFailed = false;

  @override
  void didUpdateWidget(covariant _ViewerMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.localPath != widget.asset.localPath) {
      _localFileFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final localPath = widget.asset.localPath;
    if (localPath.isNotEmpty && !_localFileFailed) {
      return Image.file(
        File(localPath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) {
          if (!_localFileFailed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }
              setState(() {
                _localFileFailed = true;
              });
            });
          }
          return const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        },
      );
    }

    final store = ref.read(joblensStoreProvider);
    return FutureBuilder<String?>(
      future: store.resolveDownloadUrl(
        widget.asset,
        forceRefresh: _forceRefresh,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }

        final url = snapshot.data;
        if (url == null || url.isEmpty) {
          return const Icon(
            Icons.broken_image_outlined,
            color: Colors.white70,
            size: 40,
          );
        }

        return Image.network(
          url,
          fit: BoxFit.contain,
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
            return const Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 40,
            );
          },
        );
      },
    );
  }
}
