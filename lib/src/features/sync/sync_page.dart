import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/joblens_store.dart';
import '../../core/models/cloud_provider.dart';
import '../../core/models/provider_account.dart';
import '../../core/models/sync_log_entry.dart';
import '../../core/models/sync_job.dart';
import '../../core/ui/user_facing_error.dart';
import '../auth/auth_page.dart';
import '../auth/auth_state.dart';
import 'devices_page.dart';

class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage>
    with WidgetsBindingObserver {
  CloudProviderType? _connectingProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      ref.read(joblensStoreProvider).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);
    final isAuthConfigured = ref.watch(authConfigurationProvider);
    final authUser = ref.watch(authUserProvider);
    final canSyncWithCloud = isAuthConfigured && authUser != null;
    final activeProviderAccounts = store.providers
        .where((provider) => provider.hasActiveConnection)
        .toList(growable: false);
    final lockedProvider = activeProviderAccounts.isEmpty
        ? null
        : activeProviderAccounts.first;
    final queuedCount = store.syncJobs
        .where((job) => job.state == SyncJobState.queued)
        .length;
    final uploadingCount = store.syncJobs
        .where((job) => job.state == SyncJobState.uploading)
        .length;
    final failedCount = store.syncJobs
        .where((job) => job.state == SyncJobState.failed)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          IconButton(
            onPressed: !canSyncWithCloud
                ? null
                : () => _reconcileAllProjects(context, store),
            icon: const Icon(Icons.travel_explore_outlined),
            tooltip: 'Rescan cloud',
          ),
          IconButton(
            onPressed: store.isBusy || !canSyncWithCloud
                ? null
                : store.runSyncNow,
            icon: const Icon(Icons.play_circle_outline),
            tooltip: 'Run sync now',
          ),
          IconButton(
            onPressed: store.isBusy || !canSyncWithCloud
                ? null
                : store.retryFailedSyncJobs,
            icon: const Icon(Icons.refresh_outlined),
            tooltip: 'Retry failed',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: store.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (store.isBusy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            if (!isAuthConfigured) ...[
              _AuthStatusCard(
                title: 'Cloud sync unavailable',
                message:
                    'You can still capture and organize photos on this device. Cloud sync will appear here when it is available.',
              ),
              const SizedBox(height: 12),
            ] else if (authUser == null) ...[
              _AuthStatusCard(
                title: 'Sign in required',
                message:
                    'Sign in to your Joblens account before connecting Google Drive, OneDrive, Dropbox, Box, or Nextcloud.',
                actionLabel: 'Sign in',
                onPressed: () => _openAuthPage(context),
              ),
              const SizedBox(height: 12),
            ] else ...[
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(authUser.email ?? 'Signed in'),
                ),
              ),
            ],
            if (userFacingStoreError(store.lastError) case final error?) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'Sync Status',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _SyncStatusCard(
              queuedCount: queuedCount,
              uploadingCount: uploadingCount,
              failedCount: failedCount,
              selectedProviderAccount: lockedProvider,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SyncActivityPage(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Cloud Providers',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (canSyncWithCloud)
              for (final providerAccount in store.providers)
                () {
                  final isLocked = _isProviderLocked(
                    providerAccount,
                    lockedProvider,
                  );
                  final isFutureIntegration = _isFutureIntegration(
                    providerAccount.providerType,
                  );
                  final canStartConnect =
                      !store.isBusy &&
                      _connectingProvider != providerAccount.providerType &&
                      !isLocked &&
                      !isFutureIntegration;
                  return _ProviderConnectionCard(
                    providerAccount: providerAccount,
                    isFutureIntegration: isFutureIntegration,
                    isOpening:
                        _connectingProvider == providerAccount.providerType,
                    canConnect: canStartConnect,
                    onConnect: canStartConnect
                        ? () => _connectProvider(context, providerAccount)
                        : null,
                    onDisconnect:
                        providerAccount.tokenState !=
                                ProviderTokenState.disconnected &&
                            !store.isBusy
                        ? () => store.disconnectProvider(
                            providerAccount.providerType,
                          )
                        : null,
                  );
                }(),
            const SizedBox(height: 10),
            Text(
              'Devices',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.devices_outlined),
                title: const Text('Signed-in devices'),
                subtitle: const Text(
                  'View and sign out other devices using your Joblens account.',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: canSyncWithCloud,
                onTap: !canSyncWithCloud
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DevicesPage(),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAuthPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AuthPage()));
  }

  Future<void> _connectProvider(
    BuildContext context,
    ProviderAccount providerAccount,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (providerAccount.providerType == CloudProviderType.nextcloud) {
      await _configureNextcloud(context);
      return;
    }

    final store = ref.read(joblensStoreProvider);
    if (_connectingProvider == providerAccount.providerType) {
      return;
    }

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connect ${providerAccount.providerType.label}',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              'We’ll open ${providerAccount.providerType.label} securely in your browser. Joblens will prepare its folder and sync in the background while you keep using the app.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _connectingProvider = providerAccount.providerType;
    });

    try {
      debugPrint(
        'Joblens provider connect request start: ${providerAccount.providerType.key}',
      );
      final authUrl = await store.beginProviderConnection(
        providerAccount.providerType,
      );
      debugPrint(
        'Joblens provider authorization URL received: ${providerAccount.providerType.key}',
      );
      if (!mounted || authUrl == null || authUrl.isEmpty) {
        return;
      }

      final launched = await launchUrl(
        Uri.parse(authUrl),
        mode: LaunchMode.externalApplication,
      );
      debugPrint(
        'Joblens provider browser launch: ${providerAccount.providerType.key} launched=$launched',
      );
      if (!mounted) {
        return;
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            launched
                ? 'Complete sign-in in your browser, then return to Joblens.'
                : 'Unable to open provider sign-in link.',
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Joblens provider connect failed: ${providerAccount.providerType.key} $error\n$stackTrace',
      );
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Unable to start ${providerAccount.providerType.label} sign-in: $error',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          if (_connectingProvider == providerAccount.providerType) {
            _connectingProvider = null;
          }
        });
      }
    }
  }

  Future<void> _configureNextcloud(BuildContext context) async {
    final store = ref.read(joblensStoreProvider);
    final serverController = TextEditingController();
    final usernameController = TextEditingController();
    final appPasswordController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Connect Nextcloud'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: serverController,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://cloud.example.com',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: appPasswordController,
                  decoration: const InputDecoration(labelText: 'App Password'),
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await store.connectNextcloud(
                  serverUrl: serverController.text.trim(),
                  username: usernameController.text.trim(),
                  appPassword: appPasswordController.text,
                );
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
  }

  bool _isProviderLocked(
    ProviderAccount providerAccount,
    ProviderAccount? lockedProvider,
  ) {
    if (lockedProvider == null) {
      return false;
    }
    return providerAccount.providerType != lockedProvider.providerType &&
        providerAccount.tokenState == ProviderTokenState.disconnected;
  }

  Future<void> _reconcileAllProjects(
    BuildContext context,
    JoblensStore store,
  ) async {
    final scheduled = await store.reconcileAllProjects();
    if (!context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          scheduled == 0
              ? 'No synced projects are ready for cloud reconcile.'
              : 'Requested cloud rescan for $scheduled project${scheduled == 1 ? '' : 's'}.',
        ),
      ),
    );
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({
    required this.queuedCount,
    required this.uploadingCount,
    required this.failedCount,
    required this.selectedProviderAccount,
    required this.onTap,
  });

  final int queuedCount;
  final int uploadingCount;
  final int failedCount;
  final ProviderAccount? selectedProviderAccount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final provider = selectedProviderAccount;
    final providerStatusText = provider == null
        ? 'No cloud provider connected'
        : provider.isExpired
        ? '${provider.providerType.label} needs attention'
        : provider.syncHealth == 'failed'
        ? '${provider.providerType.label} failed'
        : provider.syncHealth == 'degraded'
        ? '${provider.providerType.label} needs attention'
        : '${provider.providerType.label} connected';
    final providerStatusDetail = provider == null
        ? null
        : provider.openConflictCount > 0
        ? '${provider.openConflictCount} provider conflict${provider.openConflictCount == 1 ? '' : 's'} require review.'
        : (provider.lastError?.trim().isNotEmpty ?? false)
        ? provider.lastError!.trim()
        : null;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          providerStatusText,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (providerStatusDetail != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              providerStatusDetail,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        if (selectedProviderAccount?.connectedAccountLabel
                            case final account?)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              account,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CountChip(
                    label: 'Queued',
                    count: queuedCount,
                    icon: Icons.schedule,
                  ),
                  _CountChip(
                    label: 'Uploading',
                    count: uploadingCount,
                    icon: Icons.cloud_upload_outlined,
                  ),
                  _CountChip(
                    label: 'Failed',
                    count: failedCount,
                    icon: Icons.error_outline,
                    highlight: failedCount > 0,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isFutureIntegration(CloudProviderType provider) {
  return provider == CloudProviderType.box ||
      provider == CloudProviderType.nextcloud;
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.label,
    required this.count,
    required this.icon,
    this.highlight = false,
  });

  final String label;
  final int count;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = highlight ? scheme.onErrorContainer : scheme.onSurface;
    final background = highlight
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(
            '$label: $count',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

class _SyncActivityPage extends ConsumerWidget {
  const _SyncActivityPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final recentLogs = store.syncLogs.take(100).toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Activity'),
        actions: [
          IconButton(
            onPressed: store.syncLogs.isEmpty
                ? null
                : () => _shareSyncLog(context, store),
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Export sync log',
          ),
          IconButton(
            onPressed: store.isBusy || store.syncLogs.isEmpty
                ? null
                : store.clearSyncLog,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear sync log',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (recentLogs.isEmpty)
            Card(
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No sync activity logged yet.'),
              ),
            )
          else
            for (final log in recentLogs)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    log.isError
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                  ),
                  title: Text(log.message),
                  subtitle: Text(_formatSyncLogMeta(log)),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _shareSyncLog(BuildContext context, JoblensStore store) async {
    final messenger = ScaffoldMessenger.of(context);
    final shareOrigin = _sharePositionOrigin(context);
    try {
      final file = await store.exportSyncLog();
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          text: 'Joblens sync log',
          subject: 'Joblens Sync Log',
          sharePositionOrigin: shareOrigin,
        ),
      );
      if (!context.mounted) {
        return;
      }
      final message = switch (result.status) {
        ShareResultStatus.success => 'Sync log shared successfully.',
        ShareResultStatus.dismissed =>
          'Share sheet closed. You can export again any time.',
        _ => 'Sync log ready to share or save from the share sheet.',
      };
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Unable to open share sheet: $error')),
      );
    }
  }
}

String _formatSyncLogMeta(SyncLogEntry log) {
  final parts = <String>[
    _formatSyncTimestamp(log.createdAt),
    log.event,
    if (log.assetId != null && log.assetId!.isNotEmpty)
      'asset ${log.assetId!.substring(0, 8)}',
    if (log.projectId != null) 'project ${log.projectId}',
  ];
  return parts.join(' • ');
}

String _formatSyncTimestamp(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int input) => input.toString().padLeft(2, '0');
  return '${twoDigits(local.month)}/${twoDigits(local.day)} ${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}';
}

Rect? _sharePositionOrigin(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

class _ProviderConnectionCard extends StatelessWidget {
  const _ProviderConnectionCard({
    required this.providerAccount,
    required this.isFutureIntegration,
    required this.isOpening,
    required this.canConnect,
    required this.onConnect,
    required this.onDisconnect,
  });

  final ProviderAccount providerAccount;
  final bool isFutureIntegration;
  final bool isOpening;
  final bool canConnect;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _providerAccent(providerAccount.providerType);
    final hasActiveConnection = providerAccount.hasActiveConnection;
    final isExpired = providerAccount.isExpired;
    final canReconnect = canConnect && hasActiveConnection;
    final canShowConnect = canConnect && !hasActiveConnection;
    final effectiveAccent = isFutureIntegration ? scheme.outline : accent;
    final accountLabel = providerAccount.connectedAccountLabel;
    final rootPath = providerAccount.rootFolderPath;
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    );
    final hasConflicts = providerAccount.openConflictCount > 0;
    final statusText = isFutureIntegration
        ? 'Future integration'
        : switch (providerAccount.connectionStatus) {
            ProviderConnectionStatus.ready =>
              providerAccount.syncHealth == 'failed'
                  ? 'Sync failed'
                  : providerAccount.syncHealth == 'degraded'
                  ? 'Needs attention'
                  : 'Connected',
            ProviderConnectionStatus.connectedBootstrapping =>
              'Preparing library',
            ProviderConnectionStatus.connecting => 'Connecting',
            ProviderConnectionStatus.switchInProgress => 'Switching provider',
            ProviderConnectionStatus.reconnectRequired => 'Needs attention',
            ProviderConnectionStatus.failed => 'Connection failed',
            ProviderConnectionStatus.disconnected => 'Not connected',
          };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Opacity(
          opacity: isFutureIntegration ? 0.55 : 1,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProviderLogoCircle(provider: providerAccount.providerType),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(providerAccount.providerType.label, style: titleStyle),
                    const SizedBox(height: 3),
                    Text(
                      statusText,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: isFutureIntegration
                            ? scheme.onSurfaceVariant
                            : isExpired
                            ? scheme.error
                            : effectiveAccent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!isFutureIntegration && hasConflicts)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${providerAccount.openConflictCount} provider conflict${providerAccount.openConflictCount == 1 ? '' : 's'} require review.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    if (isFutureIntegration)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Coming later. Not available to connect yet.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    if (!isFutureIntegration && accountLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          accountLabel,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (!isFutureIntegration && rootPath != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          rootPath,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    if (!isFutureIntegration &&
                        !hasConflicts &&
                        (providerAccount.lastError?.trim().isNotEmpty ?? false))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          providerAccount.lastError!.trim(),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              if (isFutureIntegration)
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 110),
                  child: FilledButton(
                    onPressed: null,
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurfaceVariant,
                      disabledBackgroundColor: scheme.surfaceContainerHighest,
                      disabledForegroundColor: scheme.onSurfaceVariant,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Soon'),
                  ),
                )
              else if (hasActiveConnection) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 110),
                  child: FilledButton(
                    onPressed: canReconnect ? onConnect : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: isExpired
                          ? scheme.error
                          : effectiveAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: Text(isOpening ? 'Opening...' : 'Reconnect'),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 110),
                  child: OutlinedButton(
                    onPressed: onDisconnect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isExpired
                          ? scheme.error
                          : effectiveAccent,
                      side: BorderSide(
                        color: isExpired ? scheme.error : effectiveAccent,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: const Text('Disconnect'),
                  ),
                ),
              ] else
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 110),
                  child: FilledButton(
                    onPressed: canShowConnect ? onConnect : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: effectiveAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: Text(isOpening ? 'Opening...' : 'Connect'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderLogoCircle extends StatelessWidget {
  const _ProviderLogoCircle({required this.provider});

  final CloudProviderType provider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _providerLogoBackground(provider),
        border: Border.all(
          color: provider == CloudProviderType.googleDrive
              ? scheme.outlineVariant
              : Colors.transparent,
        ),
      ),
      child: Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CustomPaint(painter: _ProviderLogoPainter(provider)),
        ),
      ),
    );
  }
}

Color _providerAccent(CloudProviderType provider) {
  return switch (provider) {
    CloudProviderType.googleDrive => const Color(0xFF1A73E8),
    CloudProviderType.oneDrive => const Color(0xFF0078D4),
    CloudProviderType.dropbox => const Color(0xFF0061FF),
    CloudProviderType.nextcloud => const Color(0xFF0082C9),
    CloudProviderType.box => const Color(0xFF0061D5),
    CloudProviderType.backend => const Color(0xFF276749),
  };
}

Color _providerLogoBackground(CloudProviderType provider) {
  return switch (provider) {
    CloudProviderType.googleDrive => Colors.white,
    CloudProviderType.oneDrive => const Color(0xFF0078D4),
    CloudProviderType.dropbox => const Color(0xFF0061FF),
    CloudProviderType.nextcloud => const Color(0xFF0082C9),
    CloudProviderType.box => const Color(0xFF0061D5),
    CloudProviderType.backend => const Color(0xFF276749),
  };
}

class _ProviderLogoPainter extends CustomPainter {
  _ProviderLogoPainter(this.provider);

  final CloudProviderType provider;

  @override
  void paint(Canvas canvas, Size size) {
    switch (provider) {
      case CloudProviderType.googleDrive:
        _paintGoogleDrive(canvas, size);
      case CloudProviderType.oneDrive:
        _paintOneDrive(canvas, size);
      case CloudProviderType.dropbox:
        _paintDropbox(canvas, size);
      case CloudProviderType.nextcloud:
        _paintNextcloud(canvas, size);
      case CloudProviderType.box:
        _paintBox(canvas, size);
      case CloudProviderType.backend:
        _paintBackend(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant _ProviderLogoPainter oldDelegate) {
    return oldDelegate.provider != provider;
  }

  void _paintGoogleDrive(Canvas canvas, Size size) {
    final green = Paint()..color = const Color(0xFF0F9D58);
    final yellow = Paint()..color = const Color(0xFFF4B400);
    final blue = Paint()..color = const Color(0xFF4285F4);

    final left = Path()
      ..moveTo(size.width * 0.28, size.height * 0.72)
      ..lineTo(size.width * 0.46, size.height * 0.40)
      ..lineTo(size.width * 0.56, size.height * 0.40)
      ..lineTo(size.width * 0.38, size.height * 0.72)
      ..close();
    canvas.drawPath(left, green);

    final right = Path()
      ..moveTo(size.width * 0.54, size.height * 0.22)
      ..lineTo(size.width * 0.78, size.height * 0.64)
      ..lineTo(size.width * 0.68, size.height * 0.64)
      ..lineTo(size.width * 0.46, size.height * 0.28)
      ..close();
    canvas.drawPath(right, yellow);

    final bottom = Path()
      ..moveTo(size.width * 0.38, size.height * 0.72)
      ..lineTo(size.width * 0.68, size.height * 0.72)
      ..lineTo(size.width * 0.78, size.height * 0.64)
      ..lineTo(size.width * 0.48, size.height * 0.64)
      ..close();
    canvas.drawPath(bottom, blue);
  }

  void _paintOneDrive(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;
    final path = Path();
    path.moveTo(size.width * 0.22, size.height * 0.62);
    path.cubicTo(
      size.width * 0.22,
      size.height * 0.46,
      size.width * 0.34,
      size.height * 0.36,
      size.width * 0.48,
      size.height * 0.40,
    );
    path.cubicTo(
      size.width * 0.54,
      size.height * 0.26,
      size.width * 0.73,
      size.height * 0.24,
      size.width * 0.82,
      size.height * 0.38,
    );
    path.cubicTo(
      size.width * 0.92,
      size.height * 0.40,
      size.width * 0.96,
      size.height * 0.49,
      size.width * 0.92,
      size.height * 0.60,
    );
    path.cubicTo(
      size.width * 0.88,
      size.height * 0.71,
      size.width * 0.78,
      size.height * 0.76,
      size.width * 0.66,
      size.height * 0.76,
    );
    path.lineTo(size.width * 0.36, size.height * 0.76);
    path.cubicTo(
      size.width * 0.27,
      size.height * 0.76,
      size.width * 0.19,
      size.height * 0.71,
      size.width * 0.17,
      size.height * 0.64,
    );
    path.close();
    canvas.drawPath(path, paint);
  }

  void _paintDropbox(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;

    Path diamond(double cx, double cy, double w, double h) {
      return Path()
        ..moveTo(cx, cy - h / 2)
        ..lineTo(cx + w / 2, cy)
        ..lineTo(cx, cy + h / 2)
        ..lineTo(cx - w / 2, cy)
        ..close();
    }

    final w = size.width * 0.24;
    final h = size.height * 0.20;
    canvas.drawPath(
      diamond(size.width * 0.34, size.height * 0.34, w, h),
      paint,
    );
    canvas.drawPath(
      diamond(size.width * 0.66, size.height * 0.34, w, h),
      paint,
    );
    canvas.drawPath(
      diamond(size.width * 0.34, size.height * 0.58, w, h),
      paint,
    );
    canvas.drawPath(
      diamond(size.width * 0.66, size.height * 0.58, w, h),
      paint,
    );
    canvas.drawPath(
      diamond(size.width * 0.50, size.height * 0.78, w * 0.9, h * 0.75),
      paint,
    );
  }

  void _paintNextcloud(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.10
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;
    final left = Offset(size.width * 0.22, size.height * 0.56);
    final center = Offset(size.width * 0.50, size.height * 0.56);
    final right = Offset(size.width * 0.78, size.height * 0.56);
    canvas.drawLine(left, center, line);
    canvas.drawLine(center, right, line);
    canvas.drawCircle(left, size.width * 0.12, fill);
    canvas.drawCircle(center, size.width * 0.17, fill);
    canvas.drawCircle(right, size.width * 0.12, fill);
  }

  void _paintBox(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'box',
        style: TextStyle(
          color: Colors.white,
          fontSize: size.width * 0.42,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.3,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(
        (size.width - textPainter.width) / 2,
        (size.height - textPainter.height) / 2,
      ),
    );
  }

  void _paintBackend(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.10
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    final path = Path()
      ..moveTo(size.width * 0.22, size.height * 0.68)
      ..lineTo(size.width * 0.42, size.height * 0.48)
      ..lineTo(size.width * 0.56, size.height * 0.60)
      ..lineTo(size.width * 0.78, size.height * 0.34);
    canvas.drawPath(path, paint);
  }
}

class _AuthStatusCard extends StatelessWidget {
  const _AuthStatusCard({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onPressed,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(message),
            if (actionLabel != null && onPressed != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onPressed, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
