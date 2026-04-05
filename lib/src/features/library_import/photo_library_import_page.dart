import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app/joblens_store.dart';
import '../../core/models/library_import_mode.dart';

class PhotoLibraryImportPage extends ConsumerStatefulWidget {
  const PhotoLibraryImportPage({super.key});

  @override
  ConsumerState<PhotoLibraryImportPage> createState() =>
      _PhotoLibraryImportPageState();
}

class _PhotoLibraryImportPageState
    extends ConsumerState<PhotoLibraryImportPage> {
  final Set<String> _selectedIds = <String>{};
  final List<AssetEntity> _assets = <AssetEntity>[];
  final ScrollController _scrollController = ScrollController();

  AssetPathEntity? _selectedAlbum;
  bool _isLoading = true;
  bool _isImporting = false;
  bool _hasMore = true;
  PermissionState _permissionState = PermissionState.denied;
  int _page = 0;
  static const int _pageSize = 120;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _initialize();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    _permissionState = permission;
    if (!permission.hasAccess) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        imageOption: const FilterOption(),
      ),
    );

    if (!mounted) {
      return;
    }

    if (albums.isEmpty) {
      setState(() {
        _selectedAlbum = null;
        _isLoading = false;
        _hasMore = false;
      });
      return;
    }

    setState(() {
      _selectedAlbum = albums.first;
      _isLoading = false;
    });
    await _loadNextPage(reset: true);
  }

  Future<void> _loadNextPage({bool reset = false}) async {
    final album = _selectedAlbum;
    if (album == null) {
      return;
    }
    if (_isLoading || (!_hasMore && !reset)) {
      return;
    }

    setState(() {
      _isLoading = true;
      if (reset) {
        _page = 0;
        _hasMore = true;
        _assets.clear();
        _selectedIds.clear();
      }
    });

    final nextAssets = await album.getAssetListPaged(page: _page, size: _pageSize);

    if (!mounted) {
      return;
    }

    setState(() {
      _assets.addAll(nextAssets);
      _page += 1;
      _hasMore = nextAssets.length == _pageSize;
      _isLoading = false;
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _isLoading || !_hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 800) {
      _loadNextPage();
    }
  }

  Future<void> _importSelected() async {
    if (_selectedIds.isEmpty || _isImporting) {
      return;
    }
    final store = ref.read(joblensStoreProvider);
    final selectedAssets = _assets
        .where((asset) => _selectedIds.contains(asset.id))
        .toList(growable: false);

    setState(() {
      _isImporting = true;
    });

    await store.importFromPhoneLibraryAssets(
      selectedAssets,
      mode: store.libraryImportMode,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isImporting = false;
    });

    if (store.lastError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(store.lastError!)),
      );
      return;
    }

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final importMode = ref.watch(joblensStoreListenableProvider).libraryImportMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Photos'),
        actions: [
          TextButton(
            onPressed: _selectedIds.isEmpty || _isImporting ? null : _importSelected,
            child: Text(_isImporting ? 'Importing...' : 'Import'),
          ),
        ],
      ),
      body: switch (_permissionState) {
        PermissionState.authorized || PermissionState.limited => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        importMode == LibraryImportMode.move
                            ? 'Imported photos will be deleted from phone storage after they are added to Joblens.'
                            : 'Imported photos will stay in phone storage.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _assets.isEmpty && _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : GridView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: _assets.length,
                        itemBuilder: (context, index) {
                          final asset = _assets[index];
                          final selected = _selectedIds.contains(asset.id);
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                if (selected) {
                                  _selectedIds.remove(asset.id);
                                } else {
                                  _selectedIds.add(asset.id);
                                }
                              });
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                _AssetThumb(asset: asset),
                                if (selected)
                                  Container(
                                    color: Colors.black.withValues(alpha: 0.28),
                                  ),
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: CircleAvatar(
                                    radius: 12,
                                    backgroundColor: selected
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.black.withValues(alpha: 0.45),
                                    child: Icon(
                                      selected
                                          ? Icons.check
                                          : Icons.circle_outlined,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        PermissionState.denied ||
        PermissionState.notDetermined ||
        PermissionState.restricted => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Allow photo library access to import photos into Joblens.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _initialize,
                    child: const Text('Allow access'),
                  ),
                ],
              ),
            ),
          ),
      },
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.asset});

  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(
        const ThumbnailSize.square(400),
      ),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const Icon(Icons.image_outlined),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}
