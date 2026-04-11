enum CaptureTargetMode {
  inbox('inbox'),
  lastUsed('last_used'),
  fixedProject('fixed_project');

  const CaptureTargetMode(this.storageValue);

  final String storageValue;

  static CaptureTargetMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) {
        return mode;
      }
    }
    return CaptureTargetMode.inbox;
  }
}

class CaptureTargetPreference {
  const CaptureTargetPreference({
    required this.mode,
    this.fixedProjectId,
    this.lastUsedProjectId,
  });

  final CaptureTargetMode mode;
  final int? fixedProjectId;
  final int? lastUsedProjectId;

  static const defaults = CaptureTargetPreference(mode: CaptureTargetMode.inbox);

  CaptureTargetPreference copyWith({
    CaptureTargetMode? mode,
    int? fixedProjectId,
    bool clearFixedProjectId = false,
    int? lastUsedProjectId,
    bool clearLastUsedProjectId = false,
  }) {
    return CaptureTargetPreference(
      mode: mode ?? this.mode,
      fixedProjectId: clearFixedProjectId
          ? null
          : fixedProjectId ?? this.fixedProjectId,
      lastUsedProjectId: clearLastUsedProjectId
          ? null
          : lastUsedProjectId ?? this.lastUsedProjectId,
    );
  }
}

class ResolvedCaptureTarget {
  const ResolvedCaptureTarget({
    required this.projectId,
    required this.projectName,
  });

  final int projectId;
  final String projectName;
}
