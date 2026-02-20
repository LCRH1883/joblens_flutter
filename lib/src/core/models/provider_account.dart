import 'cloud_provider.dart';

enum ProviderTokenState { disconnected, connected, expired }

class ProviderAccount {
  const ProviderAccount({
    required this.id,
    required this.providerType,
    required this.displayName,
    required this.tokenState,
    required this.connectedAt,
  });

  final String id;
  final CloudProviderType providerType;
  final String displayName;
  final ProviderTokenState tokenState;
  final DateTime? connectedAt;

  bool get isConnected => tokenState == ProviderTokenState.connected;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'provider_type': providerType.key,
      'display_name': displayName,
      'token_state': tokenState.name,
      'connected_at': connectedAt?.toIso8601String(),
    };
  }

  factory ProviderAccount.fromMap(Map<String, Object?> map) {
    return ProviderAccount(
      id: map['id']! as String,
      providerType: CloudProviderTypeX.fromKey(map['provider_type']! as String),
      displayName: map['display_name']! as String,
      tokenState: ProviderTokenState.values.byName(
        map['token_state']! as String,
      ),
      connectedAt: map['connected_at'] == null
          ? null
          : DateTime.parse(map['connected_at']! as String),
    );
  }
}
