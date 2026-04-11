import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

final cameraSettingsRepositoryProvider = Provider<CameraSettingsRepository>(
  (ref) => CameraSettingsRepository(),
);

typedef CameraSettingsFileResolver = Future<File> Function();

class CameraSettingsRepository {
  CameraSettingsRepository({CameraSettingsFileResolver? fileResolver})
    : _fileResolver = fileResolver ?? _defaultFileResolver;

  final CameraSettingsFileResolver _fileResolver;

  Future<CameraSettings> read() async {
    try {
      final file = await _fileResolver();
      if (!await file.exists()) {
        return CameraSettings.defaults;
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return CameraSettings.defaults;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return CameraSettings.defaults;
      }

      return CameraSettings.fromJson(decoded);
    } catch (_) {
      return CameraSettings.defaults;
    }
  }

  Future<void> write(CameraSettings settings) async {
    try {
      final file = await _fileResolver();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {
      // Ignore persistence failures and keep capture flow unaffected.
    }
  }

  static Future<File> _defaultFileResolver() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/camera_settings.json');
  }
}

class CameraSettings {
  const CameraSettings({
    required this.rapidCaptureMode,
    required this.flashMode,
    required this.lensDirection,
    required this.zoomStop,
  });

  final bool rapidCaptureMode;
  final FlashMode flashMode;
  final CameraLensDirection lensDirection;
  final double zoomStop;

  static const defaults = CameraSettings(
    rapidCaptureMode: true,
    flashMode: FlashMode.off,
    lensDirection: CameraLensDirection.back,
    zoomStop: 1.0,
  );

  CameraSettings copyWith({
    bool? rapidCaptureMode,
    FlashMode? flashMode,
    CameraLensDirection? lensDirection,
    double? zoomStop,
  }) {
    return CameraSettings(
      rapidCaptureMode: rapidCaptureMode ?? this.rapidCaptureMode,
      flashMode: flashMode ?? this.flashMode,
      lensDirection: lensDirection ?? this.lensDirection,
      zoomStop: zoomStop ?? this.zoomStop,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'rapidCaptureMode': rapidCaptureMode,
      'flashMode': flashMode.name,
      'lensDirection': lensDirection.name,
      'zoomStop': zoomStop,
    };
  }

  static CameraSettings fromJson(Map<String, dynamic> json) {
    final rapidCaptureMode = json.containsKey('rapidCaptureMode')
        ? json['rapidCaptureMode'] == true
        : CameraSettings.defaults.rapidCaptureMode;
    final flashMode = _flashModeFromWire(json['flashMode'] as String?);
    final lensDirection = _lensDirectionFromWire(
      json['lensDirection'] as String? ?? json['cameraName'] as String?,
    );
    final zoomStop =
        (json['zoomStop'] as num?)?.toDouble() ??
        (json['zoomLevel'] as num?)?.toDouble() ??
        1.0;

    return CameraSettings(
      rapidCaptureMode: rapidCaptureMode,
      flashMode: flashMode,
      lensDirection: lensDirection,
      zoomStop: zoomStop,
    );
  }

  static FlashMode _flashModeFromWire(String? value) {
    return switch (value) {
      'auto' => FlashMode.auto,
      'always' => FlashMode.always,
      'on' => FlashMode.always,
      'torch' => FlashMode.torch,
      _ => FlashMode.off,
    };
  }

  static CameraLensDirection _lensDirectionFromWire(String? value) {
    return switch (value) {
      'front' => CameraLensDirection.front,
      _ => CameraLensDirection.back,
    };
  }
}
