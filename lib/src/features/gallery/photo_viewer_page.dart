import 'dart:io';

import 'package:flutter/material.dart';

class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    super.key,
    required this.paths,
    required this.initialIndex,
  }) : assert(paths.length > 0),
       assert(initialIndex >= 0),
       assert(initialIndex < paths.length);

  final List<String> paths;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
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
        title: Text('${_currentIndex + 1} / ${widget.paths.length}'),
      ),
      body: PageView.builder(
        controller: _pageController,
        physics: _isCurrentZoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: widget.paths.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
            _isCurrentZoomed = _isZoomed(index);
          });
        },
        itemBuilder: (context, index) {
          final transformController = _controllerFor(index);
          return Center(
            child: InteractiveViewer(
              transformationController: transformController,
              minScale: 1,
              maxScale: 4,
              onInteractionUpdate: (_) => _syncZoomState(),
              onInteractionEnd: (_) => _syncZoomState(),
              child: Image.file(
                File(widget.paths[index]),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 40,
                ),
              ),
            ),
          );
        },
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
