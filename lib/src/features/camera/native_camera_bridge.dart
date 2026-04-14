import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/models/capture_target_preference.dart';
import 'camera_settings_repository.dart';

enum NativeCameraEventType {
  previewReady,
  captureStarted,
  targetChanged,
  lensSwitchCompleted,
  lensSwitchFailed,
  targetPickerOpened,
  targetPickerFailed,
  captureSaved,
  captureFailed,
  sessionClosed;

  static NativeCameraEventType fromWire(String value) {
    return values.firstWhere(
      (type) => type.name == value,
      orElse: () => NativeCameraEventType.captureFailed,
    );
  }
}

class NativeCameraTargetOption {
  const NativeCameraTargetOption({
    required this.mode,
    required this.label,
    required this.resolvedProjectId,
    required this.resolvedProjectName,
    this.fixedProjectId,
  });

  final CaptureTargetMode mode;
  final String label;
  final int resolvedProjectId;
  final String resolvedProjectName;
  final int? fixedProjectId;
  Map<String, Object?> toMap() {
    return {
      'mode': mode.storageValue,
      'label': label,
      'resolvedProjectId': resolvedProjectId,
      'resolvedProjectName': resolvedProjectName,
      'fixedProjectId': fixedProjectId,
    };
  }
}

class NativeCameraLaunchConfig {
  const NativeCameraLaunchConfig({
    required this.sessionId,
    required this.currentMode,
    required this.currentProjectId,
    required this.currentProjectName,
    required this.targets,
    required this.settings,
  });

  final String sessionId;
  final CaptureTargetMode currentMode;
  final int currentProjectId;
  final String currentProjectName;
  final List<NativeCameraTargetOption> targets;
  final CameraSettings settings;

  String toWirePayload() {
    return jsonEncode({
      'sessionId': sessionId,
      'currentMode': currentMode.storageValue,
      'currentProjectId': currentProjectId,
      'currentProjectName': currentProjectName,
      'targets': targets
          .map((target) => target.toMap())
          .toList(growable: false),
      'settings': {
        'flashMode': settings.flashMode.name,
        'lensDirection': settings.lensDirection.name,
        'zoomStop': settings.zoomStop,
      },
    });
  }
}

class NativeCameraSessionEvent {
  const NativeCameraSessionEvent({
    required this.type,
    this.sessionId,
    this.message,
    this.photoId,
    this.localPath,
    this.targetMode,
    this.targetProjectId,
    this.targetProjectName,
    this.fixedProjectId,
    this.capturedAt,
    this.openDurationMs,
    this.captureDurationMs,
    this.durationMs,
    this.capturedCount,
    this.settings,
  });

  final NativeCameraEventType type;
  final String? sessionId;
  final String? message;
  final String? photoId;
  final String? localPath;
  final CaptureTargetMode? targetMode;
  final int? targetProjectId;
  final String? targetProjectName;
  final int? fixedProjectId;
  final DateTime? capturedAt;
  final int? openDurationMs;
  final int? captureDurationMs;
  final int? durationMs;
  final int? capturedCount;
  final CameraSettings? settings;

  factory NativeCameraSessionEvent.fromDynamic(Object? event) {
    final map = (event as Map<Object?, Object?>).map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final settingsMap = map['settings'];
    return NativeCameraSessionEvent(
      type: NativeCameraEventType.fromWire((map['type'] as String?) ?? ''),
      sessionId: map['sessionId'] as String?,
      message: map['message'] as String?,
      photoId: map['photoId'] as String?,
      localPath: map['localPath'] as String?,
      targetMode: map['targetMode'] == null
          ? null
          : CaptureTargetMode.fromStorage(map['targetMode'] as String?),
      targetProjectId: _intFromDynamic(map['targetProjectId']),
      targetProjectName: map['targetProjectName'] as String?,
      fixedProjectId: _intFromDynamic(map['fixedProjectId']),
      capturedAt: map['capturedAt'] == null
          ? null
          : DateTime.tryParse(map['capturedAt'] as String),
      openDurationMs: _intFromDynamic(map['openDurationMs']),
      captureDurationMs: _intFromDynamic(map['captureDurationMs']),
      durationMs: _intFromDynamic(map['durationMs']),
      capturedCount: _intFromDynamic(map['capturedCount']),
      settings: settingsMap is Map<Object?, Object?>
          ? CameraSettings.fromJson(
              settingsMap.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
    );
  }

  static int? _intFromDynamic(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }
}

class NativeCameraBridge {
  const NativeCameraBridge();

  static const _methodChannel = MethodChannel(
    'com.intagri.joblens/native_camera',
  );
  static const _eventChannel = EventChannel(
    'com.intagri.joblens/native_camera/events',
  );

  Stream<NativeCameraSessionEvent> events() {
    return _eventChannel.receiveBroadcastStream().map(
      NativeCameraSessionEvent.fromDynamic,
    );
  }

  Future<void> openCamera(NativeCameraLaunchConfig config) {
    return _methodChannel.invokeMethod<void>(
      'openCamera',
      config.toWirePayload(),
    );
  }
}
