import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/joblens_store.dart';
import '../../core/models/app_launch_destination.dart';
import '../../core/models/app_theme_mode.dart';
import '../../core/models/photo_asset.dart';
import '../../core/ui/asset_sync_badge.dart';
import '../auth/auth_page.dart';
import '../auth/auth_state.dart';
import 'storage_page.dart';
import '../sync/sync_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Account'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openAccountPage(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync_outlined),
              title: const Text('Cloud sync'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openSyncPage(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Storage'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openStoragePage(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Appearance'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openAppearancePage(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.launch_outlined),
              title: const Text('Open app to'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openAppLaunchPage(context),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.help_outline_rounded),
              title: const Text('Help'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _openHelpPage(context),
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

  static Future<void> _openStoragePage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const StoragePage()));
  }

  static Future<void> _openAppearancePage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _AppearancePage()));
  }

  static Future<void> _openAppLaunchPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _AppLaunchPage()));
  }

  static Future<void> _openAccountPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _AccountPage()));
  }

  static Future<void> _openHelpPage(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _HelpPage()));
  }
}

class _AppLaunchPage extends ConsumerWidget {
  const _AppLaunchPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Open app to')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Column(
              children: AppLaunchDestination.values
                  .map(
                    (destination) => ListTile(
                      title: Text(destination.label),
                      trailing: destination == store.appLaunchDestination
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () {
                        ref
                            .read(joblensStoreProvider)
                            .setAppLaunchDestination(destination);
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppearancePage extends ConsumerWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
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
                    'App theme',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<AppThemeMode>(
                    segments: AppThemeMode.values
                        .map(
                          (mode) => ButtonSegment<AppThemeMode>(
                            value: mode,
                            label: Text(mode.label),
                          ),
                        )
                        .toList(growable: false),
                    selected: {store.appThemeMode},
                    onSelectionChanged: (selection) {
                      final nextMode = selection.firstOrNull;
                      if (nextMode == null) {
                        return;
                      }
                      ref.read(joblensStoreProvider).setAppThemeMode(nextMode);
                    },
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

class _AccountPage extends ConsumerWidget {
  const _AccountPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final isAuthConfigured = ref.watch(authConfigurationProvider);
    final authUser = ref.watch(authUserProvider);
    final email = authUser?.email?.trim();
    final hasEmail = email != null && email.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(hasEmail ? email : 'Not signed in'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(
                authUser == null ? Icons.login_outlined : Icons.logout_outlined,
              ),
              title: Text(authUser == null ? 'Sign in' : 'Sign out'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: !isAuthConfigured
                  ? null
                  : authUser == null
                  ? () => SettingsPage._openAuthPage(context)
                  : store.isBusy
                  ? null
                  : () async {
                      await store.signOut();
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Change email'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: !isAuthConfigured || authUser == null
                  ? null
                  : () => _showChangeEmailDialog(context),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              title: Text(
                'Delete account',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onTap: !isAuthConfigured || authUser == null || store.isBusy
                  ? null
                  : () => _showDeleteAccountDialog(context, store),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showChangeEmailDialog(BuildContext context) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Change email'),
              content: Form(
                key: formKey,
                child: TextFormField(
                  controller: controller,
                  keyboardType: TextInputType.emailAddress,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'New email'),
                  validator: (value) {
                    final email = value?.trim() ?? '';
                    if (email.isEmpty) {
                      return 'Enter your email.';
                    }
                    if (!email.contains('@')) {
                      return 'Enter a valid email.';
                    }
                    return null;
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) {
                            return;
                          }
                          setState(() {
                            isSubmitting = true;
                          });
                          try {
                            await Supabase.instance.client.auth.updateUser(
                              UserAttributes(email: controller.text.trim()),
                            );
                            if (!context.mounted) {
                              return;
                            }
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Check your new email to confirm the change.',
                                ),
                              ),
                            );
                          } catch (error) {
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Unable to change email: $error'),
                              ),
                            );
                          } finally {
                            if (context.mounted) {
                              setState(() {
                                isSubmitting = false;
                              });
                            }
                          }
                        },
                  child: Text(isSubmitting ? 'Saving...' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showDeleteAccountDialog(
    BuildContext context,
    JoblensStore store,
  ) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            return AlertDialog(
              title: const Text('Delete account'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'This deletes your Joblens account and backend data. Files, folders, and notes in your cloud drive are not deleted.',
                    ),
                    const SizedBox(height: 12),
                    const Text('Type DELETE to confirm.'),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirmation',
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().toUpperCase() != 'DELETE') {
                          return 'Type DELETE to continue.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSubmitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) {
                            return;
                          }
                          setState(() {
                            isSubmitting = true;
                          });
                          await store.deleteAccount();
                          if (!dialogContext.mounted) {
                            return;
                          }
                          if (store.lastError != null) {
                            setState(() {
                              isSubmitting = false;
                            });
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(content: Text(store.lastError!)),
                            );
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Account deleted.')),
                          );
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  child: Text(isSubmitting ? 'Deleting...' : 'Delete account'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _HelpPage extends StatelessWidget {
  const _HelpPage();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Help'),
          bottom: const TabBar(tabs: [Tab(text: 'Symbols')]),
        ),
        body: const TabBarView(children: [_SymbolsHelpTab()]),
      ),
    );
  }
}

class _SymbolsHelpTab extends StatelessWidget {
  const _SymbolsHelpTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: const [
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SymbolHelpRow(
                  symbol: Icon(Icons.check, size: 18),
                  title: 'Selected',
                  description:
                      'The photo is selected for a batch action like move, delete, or copy.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: Icon(Icons.photo_camera_outlined, size: 18),
                  title: 'Captured in Joblens',
                  description:
                      'This photo was taken with the in-app camera.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: Icon(Icons.file_download_done_outlined, size: 18),
                  title: 'Imported from phone',
                  description:
                      'This photo was imported from the device photo library or camera roll.',
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: 12),
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SymbolHelpRow(
                  symbol: AssetSyncBadge(
                    status: AssetSyncStatus.local,
                    compact: false,
                  ),
                  title: 'Local',
                  description:
                      'The photo is stored on this device and has not finished syncing yet.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: AssetSyncBadge(
                    status: AssetSyncStatus.syncing,
                    compact: false,
                  ),
                  title: 'Syncing',
                  description:
                      'Joblens is currently uploading, moving, or reconciling this photo in the background.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: AssetSyncBadge(
                    status: AssetSyncStatus.synced,
                    compact: false,
                  ),
                  title: 'Synced',
                  description:
                      'The photo exists locally and in your connected cloud account.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: AssetSyncBadge(
                    status: AssetSyncStatus.failed,
                    compact: false,
                  ),
                  title: 'Failed',
                  description:
                      'The last sync attempt failed. Open Sync for more detail or retry.',
                ),
                SizedBox(height: 12),
                _SymbolHelpRow(
                  symbol: AssetSyncBadge(
                    status: AssetSyncStatus.cloudOnly,
                    compact: false,
                  ),
                  title: 'Cloud-only',
                  description:
                      'The photo exists in the cloud and is available to download to this device.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SymbolHelpRow extends StatelessWidget {
  const _SymbolHelpRow({
    required this.symbol,
    required this.title,
    required this.description,
  });

  final Widget symbol;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72),
          child: Align(
            alignment: Alignment.topLeft,
            child: symbol,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(description),
            ],
          ),
        ),
      ],
    );
  }
}
