import 'package:flutter/material.dart';

import '../models/photo_asset.dart';

class AssetSyncBadge extends StatelessWidget {
  const AssetSyncBadge({
    super.key,
    required this.status,
    this.compact = true,
  });

  final AssetSyncStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final appearance = switch (status) {
      AssetSyncStatus.local => (
          icon: Icons.phone_iphone_rounded,
          label: 'Local',
          background: const Color(0x88000000),
          foreground: Colors.white,
        ),
      AssetSyncStatus.syncing => (
          icon: Icons.sync_rounded,
          label: 'Syncing',
          background: scheme.primaryContainer.withValues(alpha: 0.92),
          foreground: scheme.onPrimaryContainer,
        ),
      AssetSyncStatus.synced => (
          icon: Icons.cloud_done_rounded,
          label: 'Synced',
          background: scheme.tertiaryContainer.withValues(alpha: 0.92),
          foreground: scheme.onTertiaryContainer,
        ),
      AssetSyncStatus.failed => (
          icon: Icons.error_outline_rounded,
          label: 'Failed',
          background: scheme.errorContainer.withValues(alpha: 0.94),
          foreground: scheme.onErrorContainer,
        ),
      AssetSyncStatus.cloudOnly => (
          icon: Icons.cloud_queue_rounded,
          label: 'Cloud-only',
          background: scheme.secondaryContainer.withValues(alpha: 0.92),
          foreground: scheme.onSecondaryContainer,
        ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: appearance.background,
        borderRadius: BorderRadius.circular(compact ? 999 : 10),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 4 : 5,
        ),
        child: compact
            ? Icon(
                appearance.icon,
                size: 12,
                color: appearance.foreground,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    appearance.icon,
                    size: 12,
                    color: appearance.foreground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    appearance.label,
                    style: TextStyle(
                      color: appearance.foreground,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
