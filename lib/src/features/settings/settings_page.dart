import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/joblens_store.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(joblensStoreListenableProvider);
    final user = Supabase.instance.client.auth.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              title: const Text('Account'),
              subtitle: Text(user?.email ?? 'Signed in'),
              trailing: TextButton(
                onPressed: store.isBusy
                    ? null
                    : () => ref.read(joblensStoreProvider).signOut(),
                child: const Text('Sign out'),
              ),
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
}
