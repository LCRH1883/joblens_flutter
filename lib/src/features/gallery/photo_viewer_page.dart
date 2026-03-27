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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${_currentIndex + 1} / ${widget.assets.length}'),
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
            final asset = widget.assets[index];
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
}

class _ViewerMedia extends ConsumerStatefulWidget {
  const _ViewerMedia({required this.asset});

  final PhotoAsset asset;

  @override
  ConsumerState<_ViewerMedia> createState() => _ViewerMediaState();
}

class _ViewerMediaState extends ConsumerState<_ViewerMedia> {
  bool _forceRefresh = false;

  @override
  Widget build(BuildContext context) {
    final localPath = widget.asset.localPath;
    if (localPath.isNotEmpty && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.broken_image_outlined,
          color: Colors.white70,
          size: 40,
        ),
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
