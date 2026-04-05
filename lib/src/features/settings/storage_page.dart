import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/library_import_mode.dart';
import '../library_import/photo_library_import_page.dart';

class StoragePage extends ConsumerWidget {
  const StoragePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Import photos'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: store.isBusy
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PhotoLibraryImportPage(),
                        ),
                      ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Import behavior',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<LibraryImportMode>(
                    segments: const [
                      ButtonSegment<LibraryImportMode>(
                        value: LibraryImportMode.move,
                        label: Text('Move'),
                      ),
                      ButtonSegment<LibraryImportMode>(
                        value: LibraryImportMode.copy,
                        label: Text('Copy'),
                      ),
                    ],
                    selected: {store.libraryImportMode},
                    onSelectionChanged: (selection) {
                      final nextMode = selection.first;
                      ref.read(joblensStoreProvider).setLibraryImportMode(nextMode);
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    store.libraryImportMode == LibraryImportMode.move
                        ? 'Move imports into Joblens and delete photos from phone storage after import.'
                        : 'Copy imports into Joblens and keep the originals in phone storage.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
