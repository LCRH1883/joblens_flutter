import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/project.dart';
import '../gallery/photo_viewer_page.dart';

class ProjectDetailPage extends ConsumerWidget {
  const ProjectDetailPage({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final assets = store.assets
        .where((asset) => asset.projectId == project.id)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(project.name)),
      body: assets.isEmpty
          ? const Center(child: Text('No photos in this project yet.'))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: assets.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
              ),
              itemBuilder: (context, index) {
                final asset = assets[index];
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PhotoViewerPage(
                          paths: assets
                              .map((item) => item.localPath)
                              .toList(growable: false),
                          initialIndex: index,
                        ),
                      ),
                    );
                  },
                  child: Image.file(
                    File(asset.thumbPath),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
