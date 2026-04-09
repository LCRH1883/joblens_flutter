import 'cloud_provider.dart';

enum ProviderTokenState { disconnected, connected, expired }

class ProviderAccount {
  const ProviderAccount({
    required this.id,
    required this.providerType,
    required this.displayName,
    this.accountIdentifier,
    required this.tokenState,
    required this.connectedAt,
  });

  final String id;
  final CloudProviderType providerType;
  final String displayName;
  final String? accountIdentifier;
  final ProviderTokenState tokenState;
  final DateTime? connectedAt;

  bool get isConnected => tokenState == ProviderTokenState.connected;
  bool get isExpired => tokenState == ProviderTokenState.expired;
  bool get hasActiveConnection =>
      tokenState == ProviderTokenState.connected ||
      tokenState == ProviderTokenState.expired;

  String? get connectedAccountLabel {
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
      'account_identifier': accountIdentifier,
      'token_state': tokenState.name,
      'connected_at': connectedAt?.toIso8601String(),
    };
  }

  factory ProviderAccount.fromMap(Map<String, Object?> map) {
    final providerType = CloudProviderTypeX.fromKey(map['provider_type']! as String);
    return ProviderAccount(
      id: map['id']! as String,
      providerType: providerType,
      displayName:
          (map['display_name'] as String?)?.trim().isNotEmpty == true
          ? map['display_name']! as String
          : providerType.label,
      accountIdentifier: map['account_identifier'] as String?,
      tokenState: ProviderTokenState.values.byName(
        map['token_state']! as String,
      ),
      connectedAt: map['connected_at'] == null
          ? null
          : DateTime.parse(map['connected_at']! as String),
    );
  }
}
