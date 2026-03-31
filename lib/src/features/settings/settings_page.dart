import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../auth/auth_page.dart';
import '../auth/auth_state.dart';
import '../sync/sync_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final isAuthConfigured = ref.watch(authConfigurationProvider);
    final authUser = ref.watch(authUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _accountDescription(
                      isAuthConfigured: isAuthConfigured,
                      authUserEmail: authUser?.email,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (isAuthConfigured && authUser == null)
                        FilledButton.icon(
                          onPressed: () => _openAuthPage(context),
                          icon: const Icon(Icons.login_outlined),
                          label: const Text('Sign in'),
                        ),
                      if (isAuthConfigured && authUser != null)
                        FilledButton.icon(
                          onPressed: store.isBusy ? null : store.signOut,
                          icon: const Icon(Icons.logout_outlined),
                          label: const Text('Sign out'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync_outlined),
              title: const Text('Cloud sync'),
              subtitle: Text(_syncDescription(store, isAuthConfigured, authUser?.email)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openSyncPage(context),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Storage model'),
              subtitle: const Text(
                'Joblens stores captured/imported photos in app-private storage and keeps them separate from the system camera roll.',
              ),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Delete policy'),
              subtitle: const Text(
                'Deleting in Joblens only removes local Joblens visibility. Cloud copies are not automatically deleted.',
              ),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Library status'),
              subtitle: Text(
                '${store.assets.length} photos • ${store.projects.length} projects • ${store.syncJobs.length} sync jobs',
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _openAuthPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AuthPage()));
  }

  static Future<void> _openSyncPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SyncPage()));
  }

  static String _accountDescription({
    required bool isAuthConfigured,
    required String? authUserEmail,
  }) {
    if (!isAuthConfigured) {
      return 'Your photos stay on this device for now. Sign-in and cloud sync will appear here when they are available.';
    }
    if (authUserEmail == null || authUserEmail.trim().isEmpty) {
      return 'You are signed out. Sign in to connect your cloud storage and sync Joblens across devices.';
    }
    return 'Signed in as $authUserEmail. Cloud provider connections and sync run through your Joblens account.';
  }

  static String _syncDescription(
    JoblensStore store,
    bool isAuthConfigured,
    String? authUserEmail,
  ) {
    if (!isAuthConfigured) {
      return 'Cloud sync is unavailable right now. Your photos still work locally on this device.';
    }
    if (authUserEmail == null || authUserEmail.trim().isEmpty) {
      return 'Sign in first, then connect your cloud drive and review sync status here.';
    }
    final queuedCount = store.syncJobs
        .where((job) => job.state.name == 'queued')
        .length;
    final failedCount = store.syncJobs
        .where((job) => job.state.name == 'failed')
        .length;
    return '$queuedCount queued • $failedCount failed • manage providers and sync activity';
  }
}
