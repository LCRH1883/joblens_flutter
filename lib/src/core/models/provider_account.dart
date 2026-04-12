import 'cloud_provider.dart';

enum ProviderTokenState { disconnected, connected, expired }

enum ProviderConnectionStatus {
  disconnected('disconnected'),
  connecting('connecting'),
  connectedBootstrapping('connected_bootstrapping'),
  ready('ready'),
  reconnectRequired('reconnect_required'),
  switchInProgress('switch_in_progress'),
  failed('failed');

  const ProviderConnectionStatus(this.storageValue);

  final String storageValue;

  static ProviderConnectionStatus fromStorage(String? value) {
    for (final status in values) {
      if (status.storageValue == value) {
        return status;
      }
    }
    return ProviderConnectionStatus.disconnected;
  }
}

class ProviderAccount {
  const ProviderAccount({
    required this.id,
    required this.providerType,
    required this.displayName,
    this.connectionId,
    this.accountIdentifier,
    required this.connectionStatus,
    required this.connectedAt,
    this.rootDisplayName,
    this.rootFolderPath,
    this.lastError,
    this.isActive = false,
    this.syncHealth = 'healthy',
    this.openConflictCount = 0,
  });

  final String id;
  final CloudProviderType providerType;
  final String displayName;
  final String? connectionId;
  final String? accountIdentifier;
  final ProviderConnectionStatus connectionStatus;
  final DateTime? connectedAt;
  final String? rootDisplayName;
  final String? rootFolderPath;
  final String? lastError;
  final bool isActive;
  final String syncHealth;
  final int openConflictCount;

  ProviderTokenState get tokenState => switch (connectionStatus) {
    ProviderConnectionStatus.ready => ProviderTokenState.connected,
    ProviderConnectionStatus.reconnectRequired => ProviderTokenState.expired,
    _ => ProviderTokenState.disconnected,
  };

  bool get isConnected => tokenState == ProviderTokenState.connected;
  bool get isExpired => tokenState == ProviderTokenState.expired;
  bool get isBootstrapping =>
      connectionStatus == ProviderConnectionStatus.connecting ||
      connectionStatus == ProviderConnectionStatus.connectedBootstrapping ||
      connectionStatus == ProviderConnectionStatus.switchInProgress;
  bool get hasActiveConnection =>
      isActive ||
      connectionStatus == ProviderConnectionStatus.ready ||
      connectionStatus == ProviderConnectionStatus.reconnectRequired ||
      connectionStatus == ProviderConnectionStatus.connectedBootstrapping ||
      connectionStatus == ProviderConnectionStatus.connecting ||
      connectionStatus == ProviderConnectionStatus.switchInProgress;

  String? get connectedAccountLabel {
    if (!hasActiveConnection) {
      return null;
    }
    final trimmedIdentifier = accountIdentifier?.trim();
    final trimmedDisplay = displayName.trim();
    final defaultLabel = providerType.label.toLowerCase();
    final customDisplay = trimmedDisplay.isNotEmpty &&
            trimmedDisplay.toLowerCase() != defaultLabel
        ? trimmedDisplay
        : null;

    if (customDisplay != null &&
        trimmedIdentifier != null &&
        trimmedIdentifier.isNotEmpty &&
        trimmedIdentifier.toLowerCase() != customDisplay.toLowerCase()) {
      return '$customDisplay • $trimmedIdentifier';
    }
    if (customDisplay != null) {
      return customDisplay;
    }
    if (trimmedIdentifier != null && trimmedIdentifier.isNotEmpty) {
      return trimmedIdentifier;
    }
    return null;
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'provider_type': providerType.key,
      'display_name': displayName,
      'connection_id': connectionId,
      'account_identifier': accountIdentifier,
      'connection_status': connectionStatus.storageValue,
      'token_state': tokenState.name,
      'connected_at': connectedAt?.toIso8601String(),
      'root_display_name': rootDisplayName,
      'root_folder_path': rootFolderPath,
      'last_error': lastError,
      'is_active': isActive ? 1 : 0,
      'sync_health': syncHealth,
      'open_conflict_count': openConflictCount,
    };
  }

  factory ProviderAccount.fromMap(Map<String, Object?> map) {
    final providerType = CloudProviderTypeX.fromKey(map['provider_type']! as String);
    final connectionStatus = ProviderConnectionStatus.fromStorage(
      map['connection_status'] as String? ??
          switch (map['token_state'] as String? ?? ProviderTokenState.disconnected.name) {
            'connected' => ProviderConnectionStatus.ready.storageValue,
            'expired' => ProviderConnectionStatus.reconnectRequired.storageValue,
            _ => ProviderConnectionStatus.disconnected.storageValue,
          },
    );
    return ProviderAccount(
      id: map['id']! as String,
      providerType: providerType,
      displayName:
          (map['display_name'] as String?)?.trim().isNotEmpty == true
          ? map['display_name']! as String
          : providerType.label,
      connectionId: map['connection_id'] as String?,
      accountIdentifier: map['account_identifier'] as String?,
      connectionStatus: connectionStatus,
      connectedAt: map['connected_at'] == null
          ? null
          : DateTime.parse(map['connected_at']! as String),
      rootDisplayName: map['root_display_name'] as String?,
      rootFolderPath: map['root_folder_path'] as String?,
      lastError: map['last_error'] as String?,
      isActive: ((map['is_active'] as int?) ?? 0) == 1,
      syncHealth: (map['sync_health'] as String?)?.trim().isNotEmpty == true
          ? (map['sync_health'] as String).trim()
          : 'healthy',
      openConflictCount: (map['open_conflict_count'] as int?) ?? 0,
    );
  }
}
