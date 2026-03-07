import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/joblens_store.dart';
import '../../core/models/cloud_provider.dart';
import '../../core/models/provider_account.dart';
import '../../core/models/sync_job.dart';

class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.resumed) {
      ref.read(joblensStoreProvider).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          IconButton(
            onPressed: store.isBusy ? null : store.runSyncNow,
            icon: const Icon(Icons.play_circle_outline),
            tooltip: 'Run sync now',
          ),
          IconButton(
            onPressed: store.isBusy ? null : store.retryFailedSyncJobs,
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
            if (store.lastError != null) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    store.lastError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'Cloud Providers',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final providerAccount in store.providers)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              providerAccount.providerType.label,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          _StatusChip(state: providerAccount.tokenState),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(_providerSubtitle(providerAccount)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: store.isBusy
                                ? null
                                : () => _connectProvider(context, providerAccount),
                            icon: Icon(
                              providerAccount.isConnected
                                  ? Icons.refresh_outlined
                                  : Icons.link_outlined,
                            ),
                            label: Text(
                              providerAccount.isConnected ? 'Reconnect' : 'Connect',
                            ),
                          ),
                          if (providerAccount.tokenState !=
                              ProviderTokenState.disconnected)
                            OutlinedButton.icon(
                              onPressed: store.isBusy
                                  ? null
                                  : () => store.clearProviderCredentials(
                                      providerAccount.providerType,
                                    ),
                              icon: const Icon(Icons.link_off_outlined),
                              label: const Text('Disconnect'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Sync Queue',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (store.syncJobs.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No sync jobs yet.'),
                ),
              ),
            for (final job in store.syncJobs)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(_iconForState(job.state)),
                  title: Text('Asset ${job.assetId.substring(0, 8)}'),
                  subtitle: Text(_subtitleForJob(job)),
                ),
              ),
          ],
        ),
      ),
    );
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
    final authUrl = await store.beginProviderOAuthConnection(
      providerAccount.providerType,
    );
    if (!mounted || authUrl == null || authUrl.isEmpty) {
      return;
    }

    final launched = await launchUrl(
      Uri.parse(authUrl),
      mode: LaunchMode.externalApplication,
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
  }

  Future<void> _configureNextcloud(BuildContext context) async {
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
                  decoration: const InputDecoration(
                    labelText: 'App Password',
                  ),
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
                await ref.read(joblensStoreProvider).connectNextcloudProvider(
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

  String _providerSubtitle(ProviderAccount providerAccount) {
    return switch (providerAccount.tokenState) {
      ProviderTokenState.connected =>
        'Connected. New and moved photos sync into this provider through the Joblens backend.',
      ProviderTokenState.expired =>
        'Connection expired. Reconnect this provider to resume sync.',
      ProviderTokenState.disconnected => providerAccount.providerType ==
              CloudProviderType.nextcloud
          ? 'Connect your Nextcloud server. Credentials are stored and refreshed by the backend.'
          : 'Connect your ${providerAccount.providerType.label} account in the browser. Tokens are stored and refreshed by the backend.',
    };
  }

  IconData _iconForState(SyncJobState state) {
    return switch (state) {
      SyncJobState.queued => Icons.schedule,
      SyncJobState.uploading => Icons.cloud_upload_outlined,
      SyncJobState.done => Icons.check_circle_outline,
      SyncJobState.failed => Icons.error_outline,
      SyncJobState.paused => Icons.pause_circle_outline,
    };
  }

  String _subtitleForJob(SyncJob job) {
    final base = 'State: ${job.state.name} • Attempts: ${job.attemptCount}';
    if (job.lastError == null || job.lastError!.isEmpty) {
      return base;
    }
    return '$base\nError: ${job.lastError}';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final ProviderTokenState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, foreground, background) = switch (state) {
      ProviderTokenState.connected => (
          'Connected',
          scheme.onPrimaryContainer,
          scheme.primaryContainer,
        ),
      ProviderTokenState.expired => (
          'Expired',
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
        ),
      ProviderTokenState.disconnected => (
          'Disconnected',
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
