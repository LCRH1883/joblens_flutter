import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/joblens_store.dart';
import '../../core/models/photo_asset.dart';
import '../../core/models/project.dart';
import '../../core/ui/thumbnail_cache_size.dart';
import 'project_detail_page.dart';

class ProjectsPage extends ConsumerWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final projects = store.projects;
    final latestAssetByProjectId = <int, PhotoAsset>{};
    for (final asset in store.assets) {
      latestAssetByProjectId.putIfAbsent(asset.projectId, () => asset);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          PopupMenuButton<ProjectSortMode>(
            tooltip: 'Sort projects',
            icon: const Icon(Icons.sort_rounded),
            initialValue: store.projectSortMode,
            onSelected: store.setProjectSortMode,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ProjectSortMode.name,
                child: Text('Sort by name'),
              ),
              PopupMenuItem(
                value: ProjectSortMode.startDate,
                child: Text('Sort by start date'),
              ),
            ],
          ),
          IconButton(
            onPressed: () => _showCreateProjectDialog(context, store),
            icon: const Icon(Icons.add),
            tooltip: 'Create project',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: store.refresh,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: projects.length,
          itemBuilder: (context, index) {
            final project = projects[index];
            final count = store.projectCounts[project.id] ?? 0;
            final latestAsset = latestAssetByProjectId[project.id];

            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectDetailPage(project: project),
                    ),
                  );
                },
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: latestAsset == null
                      ? _placeholder(context)
                      : _ProjectCoverThumbnail(
                          asset: latestAsset,
                          store: store,
                        ),
                ),
                title: Text(project.name),
                subtitle: _ProjectSubtitle(
                  photoCount: count,
                  notePreview: _notePreview(project.notes),
                  startDate: project.startDate,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'edit') {
                      await _showEditProjectDialog(context, store, project);
                    }
                    if (value == 'delete') {
                      await store.deleteProject(project.id);
                    }
                  },
                  itemBuilder: (context) {
                    return [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit details'),
                      ),
                      if (project.name != 'Inbox')
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                    ];
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.workspaces_outline),
    );
  }

  Future<void> _showCreateProjectDialog(
    BuildContext context,
    JoblensStore store,
  ) async {
    final result = await showDialog<_ProjectDetailsResult>(
      context: context,
      builder: (context) => const _ProjectDetailsDialog(
        title: 'New project',
        confirmLabel: 'Create',
      ),
    );
    if (result == null) {
      return;
    }
    await store.createProject(result.name, startDate: result.startDate);
  }

  Future<void> _showEditProjectDialog(
    BuildContext context,
    JoblensStore store,
    Project project,
  ) async {
    final result = await showDialog<_ProjectDetailsResult>(
      context: context,
      builder: (context) => _ProjectDetailsDialog(
        title: 'Edit project details',
        confirmLabel: 'Save',
        initialName: project.name,
        initialStartDate: project.startDate,
        nameEditable: project.name != 'Inbox',
      ),
    );
    if (result == null) {
      return;
    }
    await store.updateProjectMetadata(
      project.id,
      name: result.name,
      startDate: result.startDate,
    );
  }

  String? _notePreview(String notes) {
    final normalized = notes.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isNotEmpty) {
        return line;
      }
    }
    return null;
  }
}

class _ProjectCoverThumbnail extends StatefulWidget {
  const _ProjectCoverThumbnail({required this.asset, required this.store});

  final PhotoAsset asset;
  final JoblensStore store;

  @override
  State<_ProjectCoverThumbnail> createState() => _ProjectCoverThumbnailState();
}

class _ProjectCoverThumbnailState extends State<_ProjectCoverThumbnail> {
  bool _forceRefresh = false;
  bool _localThumbFailed = false;

  int _cacheDimension(BuildContext context) {
    return thumbnailCacheDimension(
      logicalSize: 56,
      devicePixelRatio: MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant _ProjectCoverThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.thumbPath != widget.asset.thumbPath) {
      _localThumbFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbPath = widget.asset.thumbPath.trim();
    final cacheDimension = _cacheDimension(context);
    if (thumbPath.isNotEmpty && !_localThumbFailed) {
      return Image.file(
        File(thumbPath),
        width: 56,
        height: 56,
        cacheWidth: cacheDimension,
        cacheHeight: cacheDimension,
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
      future: widget.store.ensurePersistentThumbnail(widget.asset),
      builder: (context, snapshot) {
        final persistedThumbPath = snapshot.data?.trim() ?? '';
        if (persistedThumbPath.isNotEmpty) {
          return Image.file(
            File(persistedThumbPath),
            width: 56,
            height: 56,
            cacheWidth: cacheDimension,
            cacheHeight: cacheDimension,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              return _buildRemoteFallback(context, cacheDimension);
            },
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return _placeholder(context, loading: true);
        }
        return _buildRemoteFallback(context, cacheDimension);
      },
    );
  }

  Widget _buildRemoteFallback(BuildContext context, int cacheDimension) {
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
          width: 56,
          height: 56,
          cacheWidth: cacheDimension,
          cacheHeight: cacheDimension,
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
      width: 56,
      height: 56,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.workspaces_outline),
    );
  }
}

class _ProjectSubtitle extends StatelessWidget {
  const _ProjectSubtitle({
    required this.photoCount,
    required this.notePreview,
    required this.startDate,
  });

  final int photoCount;
  final String? notePreview;
  final DateTime? startDate;

  @override
  Widget build(BuildContext context) {
    final metadata = <String>[
      '$photoCount photos',
      if (startDate != null)
        'Starts ${DateFormat.yMMMd().format(startDate!.toLocal())}',
    ];

    if (notePreview == null) {
      return Text(metadata.join('  •  '));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(metadata.join('  •  ')),
        Text(notePreview!, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _ProjectDetailsDialog extends StatefulWidget {
  const _ProjectDetailsDialog({
    required this.title,
    required this.confirmLabel,
    this.initialName = '',
    this.initialStartDate,
    this.nameEditable = true,
  });

  final String title;
  final String confirmLabel;
  final String initialName;
  final DateTime? initialStartDate;
  final bool nameEditable;

  @override
  State<_ProjectDetailsDialog> createState() => _ProjectDetailsDialogState();
}

class _ProjectDetailsDialogState extends State<_ProjectDetailsDialog> {
  late final TextEditingController _nameController;
  DateTime? _startDate;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _startDate = widget.initialStartDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            readOnly: !widget.nameEditable,
            decoration: InputDecoration(
              hintText: 'Project name',
              helperText: widget.nameEditable ? null : 'Inbox name is fixed.',
            ),
          ),
          const SizedBox(height: 16),
          Text('Start date', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => _pickStartDate(context),
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  _startDate == null
                      ? 'Choose date'
                      : DateFormat.yMMMd().format(_startDate!.toLocal()),
                ),
              ),
              if (_startDate != null)
                TextButton(
                  onPressed: () => setState(() {
                    _startDate = null;
                  }),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _ProjectDetailsResult(
                name: _nameController.text,
                startDate: _startDate,
              ),
            );
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  Future<void> _pickStartDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 20),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _startDate = picked;
    });
  }
}

class _ProjectDetailsResult {
  const _ProjectDetailsResult({required this.name, required this.startDate});

  final String name;
  final DateTime? startDate;
}
