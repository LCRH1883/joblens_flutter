import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/cloud_provider.dart';
import '../../core/models/provider_credentials.dart';
import '../../core/models/sync_job.dart';

class SyncPage extends ConsumerWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                          Switch.adaptive(
                            value: providerAccount.isConnected,
                            onChanged:
                                (store.credentialStatus[providerAccount
                                        .providerType] ??
                                    false)
                                ? (value) {
                                    store.setProviderConnected(
                                      providerAccount.providerType,
                                      value,
                                    );
                                  }
                                : null,
                          ),
                        ],
                      ),
                      Text(
                        _providerSubtitle(
                          providerAccount.providerType,
                          configured:
                              store.credentialStatus[providerAccount
                                  .providerType] ??
                              false,
                          connected: providerAccount.isConnected,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_supportsOAuth(providerAccount.providerType))
                            OutlinedButton.icon(
                              onPressed: () => store.connectProviderWithOAuth(
                                providerAccount.providerType,
                              ),
                              icon: const Icon(Icons.login_outlined),
                              label: const Text('OAuth Sign In'),
                            ),
                          if (providerAccount.providerType ==
                              CloudProviderType.nextcloud)
                            OutlinedButton.icon(
                              onPressed: () => _configureCredentials(
                                context,
                                store,
                                providerAccount.providerType,
                              ),
                              icon: const Icon(Icons.key_outlined),
                              label: const Text('Configure'),
                            ),
                          OutlinedButton.icon(
                            onPressed: () => store.clearProviderCredentials(
                              providerAccount.providerType,
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Clear Credentials'),
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
                  title: Text(
                    '${job.providerType.label} • Asset ${job.assetId.substring(0, 8)}',
                  ),
                  subtitle: Text(_subtitleForJob(job)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureCredentials(
    BuildContext context,
    JoblensStore store,
    CloudProviderType provider,
  ) async {
    final existing = await store.getProviderCredentials(provider);

    final tokenController = TextEditingController(
      text: existing?.accessToken ?? '',
    );
    final serverController = TextEditingController(
      text: existing?.serverUrl ?? '',
    );
    final usernameController = TextEditingController(
      text: existing?.username ?? '',
    );
    final appPasswordController = TextEditingController(
      text: existing?.appPassword ?? '',
    );

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Configure ${provider.label}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider == CloudProviderType.nextcloud) ...[
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
                ] else ...[
                  TextField(
                    controller: tokenController,
                    decoration: const InputDecoration(
                      labelText: 'Access Token',
                    ),
                    obscureText: true,
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
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
                final credentials = ProviderCredentials(
                  provider: provider,
                  accessToken: tokenController.text.trim(),
                  serverUrl: serverController.text.trim(),
                  username: usernameController.text.trim(),
                  appPassword: appPasswordController.text,
                );

                await store.saveProviderCredentials(credentials);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  String _providerSubtitle(
    CloudProviderType provider, {
    required bool configured,
    required bool connected,
  }) {
    if (!configured) {
      return switch (provider) {
        CloudProviderType.nextcloud =>
          'Credentials missing. Add server URL, username, and app password.',
        _ =>
          'OAuth not configured. Tap OAuth Sign In (requires client ID via --dart-define).',
      };
    }

    return connected
        ? 'Connected and ready to sync into Joblens/{ProjectName} folders.'
        : 'Credentials saved. Enable the switch to connect.';
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

  bool _supportsOAuth(CloudProviderType provider) {
    return provider == CloudProviderType.googleDrive ||
        provider == CloudProviderType.oneDrive ||
        provider == CloudProviderType.box;
  }
}
