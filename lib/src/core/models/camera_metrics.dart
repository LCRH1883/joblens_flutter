class CameraSessionMetrics {
  const CameraSessionMetrics({
    required this.sessionId,
    required this.platform,
    required this.openedAt,
    this.previewReadyAt,
    this.closedAt,
    this.openToPreviewReadyMs,
    this.lastCaptureLocalSaveMs,
    this.lastLensSwitchMs,
    this.lastTargetPickerOpenMs,
    required this.captureAttemptCount,
    required this.captureLocalSaveCount,
    required this.captureSuccessCount,
    required this.hardFailureCount,
    required this.abandoned,
    this.closeReason,
  });

  final String sessionId;
  final String platform;
  final DateTime openedAt;
  final DateTime? previewReadyAt;
  final DateTime? closedAt;
  final int? openToPreviewReadyMs;
  final int? lastCaptureLocalSaveMs;
  final int? lastLensSwitchMs;
  final int? lastTargetPickerOpenMs;
  final int captureAttemptCount;
  final int captureLocalSaveCount;
  final int captureSuccessCount;
  final int hardFailureCount;
  final bool abandoned;
  final String? closeReason;

  factory CameraSessionMetrics.fromMap(Map<String, Object?> map) {
    return CameraSessionMetrics(
      sessionId: map['session_id']! as String,
      platform: map['platform']! as String,
      openedAt: DateTime.parse(map['opened_at']! as String),
      previewReadyAt: (map['preview_ready_at'] as String?) == null
          ? null
          : DateTime.parse(map['preview_ready_at']! as String),
      closedAt: (map['closed_at'] as String?) == null
          ? null
          : DateTime.parse(map['closed_at']! as String),
      openToPreviewReadyMs: map['open_to_preview_ready_ms'] as int?,
      lastCaptureLocalSaveMs: map['last_capture_local_save_ms'] as int?,
      lastLensSwitchMs: map['last_lens_switch_ms'] as int?,
      lastTargetPickerOpenMs: map['last_target_picker_open_ms'] as int?,
      captureAttemptCount: (map['capture_attempt_count'] as int?) ?? 0,
      captureLocalSaveCount: (map['capture_local_save_count'] as int?) ?? 0,
      captureSuccessCount: (map['capture_success_count'] as int?) ?? 0,
      hardFailureCount: (map['hard_failure_count'] as int?) ?? 0,
      abandoned: ((map['abandoned'] as int?) ?? 0) == 1,
      closeReason: map['close_reason'] as String?,
    );
  }
}

class CameraMetricsSummary {
  const CameraMetricsSummary({
    required this.totalSessions,
    required this.previewReadySessions,
    required this.abandonedSessions,
    required this.captureAttempts,
    required this.captureSuccesses,
    required this.hardFailures,
  });

  final int totalSessions;
  final int previewReadySessions;
  final int abandonedSessions;
  final int captureAttempts;
  final int captureSuccesses;
  final int hardFailures;

  double get captureSuccessRate =>
      captureAttempts == 0 ? 0 : captureSuccesses / captureAttempts;

  double get sessionAbandonRate =>
      previewReadySessions == 0 ? 0 : abandonedSessions / previewReadySessions;
}
