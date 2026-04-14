import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/db/app_database_provider.dart';
import '../../core/models/camera_metrics.dart';
import '../../core/models/sync_log_entry.dart';

final cameraMetricsTrackerProvider = Provider<CameraMetricsTracker>(
  (ref) => CameraMetricsTracker(ref.watch(appDatabaseProvider)),
);

class CameraMetricsTracker {
  CameraMetricsTracker(this._database);

  final AppDatabase _database;

  Future<void> startSession({
    required String sessionId,
    required String platform,
  }) async {
    final openedAt = DateTime.now();
    await _database.upsertCameraSessionOpened(
      sessionId: sessionId,
      platform: platform,
      openedAt: openedAt,
    );
    await _logInfo(
      event: 'camera.session_opened',
      sessionId: sessionId,
      message: 'Camera session opened on $platform.',
    );
  }

  Future<void> recordPreviewReady({
    required String sessionId,
    int? openToPreviewReadyMs,
  }) async {
    await _database.markCameraSessionPreviewReady(
      sessionId: sessionId,
      previewReadyAt: DateTime.now(),
      openToPreviewReadyMs: openToPreviewReadyMs,
    );
    await _logInfo(
      event: 'camera.preview_ready',
      sessionId: sessionId,
      message: _messageWithDuration(
        'Camera preview became ready.',
        openToPreviewReadyMs,
      ),
    );
  }

  Future<void> recordCaptureStarted({
    required String sessionId,
    String? photoId,
  }) async {
    await _database.incrementCameraSessionCaptureAttempt(sessionId);
    await _logInfo(
      event: 'camera.capture_started',
      sessionId: sessionId,
      assetId: photoId,
      message: 'Capture started.',
    );
  }

  Future<void> recordCaptureLocalSaved({
    required String sessionId,
    String? photoId,
    int? captureLocalSaveMs,
  }) async {
    await _database.incrementCameraSessionCaptureLocalSave(
      sessionId,
      captureLocalSaveMs: captureLocalSaveMs,
    );
    await _logInfo(
      event: 'camera.capture_local_saved',
      sessionId: sessionId,
      assetId: photoId,
      message: _messageWithDuration(
        'Capture saved to local Joblens storage.',
        captureLocalSaveMs,
      ),
    );
  }

  Future<void> recordCaptureSuccess({
    required String sessionId,
    String? photoId,
  }) async {
    await _database.incrementCameraSessionCaptureSuccess(sessionId);
    await _logInfo(
      event: 'camera.capture_success',
      sessionId: sessionId,
      assetId: photoId,
      message: 'Capture ingested successfully into Joblens.',
    );
  }

  Future<void> recordCaptureFailed({
    required String sessionId,
    String? photoId,
    required String message,
  }) async {
    await _database.incrementCameraSessionHardFailure(sessionId);
    await _logError(
      event: 'camera.capture_failed',
      sessionId: sessionId,
      assetId: photoId,
      message: message,
    );
  }

  Future<void> recordOpenFailed({
    required String sessionId,
    required String message,
  }) async {
    await _database.incrementCameraSessionHardFailure(sessionId);
    await _logError(
      event: 'camera.open_failed',
      sessionId: sessionId,
      message: message,
    );
  }

  Future<void> recordIngestFailed({
    required String sessionId,
    String? photoId,
    required String message,
  }) async {
    await _database.incrementCameraSessionHardFailure(sessionId);
    await _logError(
      event: 'camera.ingest_failed',
      sessionId: sessionId,
      assetId: photoId,
      message: message,
    );
  }

  Future<void> recordLensSwitchCompleted({
    required String sessionId,
    int? durationMs,
  }) async {
    await _database.updateCameraSessionLensSwitchDuration(
      sessionId,
      durationMs: durationMs,
    );
    await _logInfo(
      event: 'camera.lens_switch_completed',
      sessionId: sessionId,
      message: _messageWithDuration('Lens switch completed.', durationMs),
    );
  }

  Future<void> recordLensSwitchFailed({
    required String sessionId,
    required String message,
    int? durationMs,
  }) async {
    await _database.incrementCameraSessionHardFailure(sessionId);
    await _database.updateCameraSessionLensSwitchDuration(
      sessionId,
      durationMs: durationMs,
    );
    await _logError(
      event: 'camera.lens_switch_failed',
      sessionId: sessionId,
      message: _messageWithDuration(message, durationMs),
    );
  }

  Future<void> recordTargetPickerOpened({
    required String sessionId,
    int? durationMs,
  }) async {
    await _database.updateCameraSessionTargetPickerDuration(
      sessionId,
      durationMs: durationMs,
    );
    await _logInfo(
      event: 'camera.target_picker_opened',
      sessionId: sessionId,
      message: _messageWithDuration(
        'Capture target picker opened.',
        durationMs,
      ),
    );
  }

  Future<void> recordTargetPickerFailed({
    required String sessionId,
    required String message,
  }) async {
    await _database.incrementCameraSessionHardFailure(sessionId);
    await _logError(
      event: 'camera.target_picker_failed',
      sessionId: sessionId,
      message: message,
    );
  }

  Future<void> completeSession({
    required String sessionId,
    required bool abandoned,
    required String closeReason,
  }) async {
    await _database.completeCameraSession(
      sessionId: sessionId,
      closedAt: DateTime.now(),
      abandoned: abandoned,
      closeReason: closeReason,
    );
    if (abandoned) {
      await _logInfo(
        event: 'camera.session_abandoned',
        sessionId: sessionId,
        message: 'Camera session reached preview and closed without any shutter taps.',
      );
    }
    await _logInfo(
      event: 'camera.session_closed',
      sessionId: sessionId,
      message: 'Camera session closed with reason: $closeReason.',
    );
  }

  Future<CameraSessionMetrics?> getSession(String sessionId) =>
      _database.getCameraSessionMetrics(sessionId);

  Future<CameraMetricsSummary> getSummary() => _database.getCameraMetricsSummary();

  Future<void> _logInfo({
    required String event,
    required String sessionId,
    required String message,
    String? assetId,
  }) {
    return _database.addSyncLog(
      level: SyncLogLevel.info,
      event: event,
      assetId: assetId,
      message: 'sessionId=$sessionId $message',
    );
  }

  Future<void> _logError({
    required String event,
    required String sessionId,
    required String message,
    String? assetId,
  }) {
    return _database.addSyncLog(
      level: SyncLogLevel.error,
      event: event,
      assetId: assetId,
      message: 'sessionId=$sessionId $message',
    );
  }

  static String _messageWithDuration(String message, int? durationMs) {
    if (durationMs == null) {
      return message;
    }
    return '$message durationMs=$durationMs';
  }
}
