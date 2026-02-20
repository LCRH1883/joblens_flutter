import 'dart:io';

import 'package:flutter/material.dart';

class PhotoViewerPage extends StatelessWidget {
  const PhotoViewerPage({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo')),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.6,
          maxScale: 4,
          child: Image.file(File(path), fit: BoxFit.contain),
        ),
      ),
    );
  }
}
