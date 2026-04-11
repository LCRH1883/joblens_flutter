import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/api/backend_api_models.dart';

class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(joblensStoreProvider).refreshSignedInDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(joblensStoreListenableProvider);
    final devices = store.signedInDevices;

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: RefreshIndicator(
        onRefresh: store.refreshSignedInDevices,
        child: ListView(
          padding: const EdgeInsets.all(12),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text(
              'Signed in devices',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Location is approximate and may be inaccurate.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (devices.isEmpty)
              Card(
                child: ListTile(
                  title: const Text('No signed-in devices registered yet'),
                  subtitle: Text(
                    store.lastError?.trim().isNotEmpty == true
                        ? store.lastError!
                        : 'Pull to refresh or retry registration. Devices appear here after the backend binds the current signed-in session to this installation.',
                  ),
                  trailing: store.isBusy
                      ? null
                      : IconButton(
                          onPressed: () => ref
                              .read(joblensStoreProvider)
                              .refreshSignedInDevices(),
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: 'Retry registration',
                        ),
                ),
              ),
            for (final device in devices)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              device.deviceName,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (device.isCurrent)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'This device',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSecondaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _DeviceMetaRow(
                        label: 'OS',
                        value: _buildPlatformLabel(device),
                      ),
                      _DeviceMetaRow(
                        label: 'Location',
                        value: device.approxLocation?.display ?? 'Unavailable',
                      ),
                      _DeviceMetaRow(
                        label: 'Last seen',
                        value: _formatLastSeen(device.lastSeenAt),
                      ),
                      _DeviceMetaRow(
                        label: 'Last sync',
                        value: device.lastSyncAt == null
                            ? 'Not synced yet'
                            : _formatLastSeen(device.lastSyncAt),
                      ),
                      if (device.signedInAt != null)
                        _DeviceMetaRow(
                          label: 'Signed in',
                          value: _formatTimestamp(device.signedInAt!),
                        ),
                      if (device.canSignOut) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            onPressed: store.isBusy
                                ? null
                                : () => _confirmSignOutDevice(device),
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Sign out'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _buildPlatformLabel(SignedInDevice device) {
    switch (device.platform.trim().toLowerCase()) {
      case 'ios':
        return 'iOS';
      case 'android':
        return 'Android';
      case 'macos':
        return 'macOS';
      default:
        final platform = device.platform.trim();
        if (platform.isEmpty) {
          return 'Unknown';
        }
        return platform;
    }
  }

  Future<void> _confirmSignOutDevice(SignedInDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Sign out this device?'),
          content: Text(
            'This will sign ${device.deviceName} out of Joblens and stop sync until it signs in again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(joblensStoreProvider).signOutDeviceSession(device.deviceId);
  }

  String _formatLastSeen(DateTime? timestamp) {
    if (timestamp == null) {
      return 'Unknown';
    }
    final now = DateTime.now();
    final difference = now.difference(timestamp.toLocal());
    if (difference.inMinutes < 1) {
      return 'Just now';
    }
    if (difference.inHours < 1) {
      return '${difference.inMinutes} min ago';
    }
    if (difference.inDays < 1) {
      return '${difference.inHours} hr ago';
    }
    return _formatTimestamp(timestamp);
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final month = _monthLabel(local.month);
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month ${local.day}, ${local.year} ${local.hour}:$minute';
  }

  String _monthLabel(int month) {
    const labels = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return labels[(month - 1).clamp(0, labels.length - 1)];
  }
}

class _DeviceMetaRow extends StatelessWidget {
  const _DeviceMetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
