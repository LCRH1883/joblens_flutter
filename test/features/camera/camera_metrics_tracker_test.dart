import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:joblens_flutter/src/core/db/app_database.dart';
import 'package:joblens_flutter/src/features/camera/camera_metrics_tracker.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('camera metrics tracker persists timings, counts, and export logs', () async {
    final tempDir = await Directory.systemTemp.createTemp('joblens_camera_metrics_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    addTearDown(database.close);
    final tracker = CameraMetricsTracker(database);

    await tracker.startSession(sessionId: 'session-1', platform: 'android');
    await tracker.recordPreviewReady(
      sessionId: 'session-1',
      openToPreviewReadyMs: 245,
    );
    await tracker.recordTargetPickerOpened(
      sessionId: 'session-1',
      durationMs: 38,
    );
    await tracker.recordLensSwitchCompleted(
      sessionId: 'session-1',
      durationMs: 182,
    );
    await tracker.recordCaptureStarted(
      sessionId: 'session-1',
      photoId: 'photo-1',
    );
    await tracker.recordCaptureLocalSaved(
      sessionId: 'session-1',
      photoId: 'photo-1',
      captureLocalSaveMs: 97,
    );
    await tracker.recordCaptureSuccess(
      sessionId: 'session-1',
      photoId: 'photo-1',
    );
    await tracker.completeSession(
      sessionId: 'session-1',
      abandoned: false,
      closeReason: 'session_closed',
    );

    final session = await tracker.getSession('session-1');
    expect(session, isNotNull);
    expect(session!.openToPreviewReadyMs, 245);
    expect(session.lastTargetPickerOpenMs, 38);
    expect(session.lastLensSwitchMs, 182);
    expect(session.lastCaptureLocalSaveMs, 97);
    expect(session.captureAttemptCount, 1);
    expect(session.captureLocalSaveCount, 1);
    expect(session.captureSuccessCount, 1);
    expect(session.hardFailureCount, 0);
    expect(session.abandoned, isFalse);
    expect(session.closeReason, 'session_closed');

    final summary = await tracker.getSummary();
    expect(summary.totalSessions, 1);
    expect(summary.previewReadySessions, 1);
    expect(summary.abandonedSessions, 0);
    expect(summary.captureAttempts, 1);
    expect(summary.captureSuccesses, 1);
    expect(summary.captureSuccessRate, 1);
    expect(summary.sessionAbandonRate, 0);

    final logs = await database.getAllSyncLogs();
    expect(logs.any((log) => log.event == 'camera.session_opened'), isTrue);
    expect(logs.any((log) => log.event == 'camera.preview_ready'), isTrue);
    expect(logs.any((log) => log.event == 'camera.capture_started'), isTrue);
    expect(logs.any((log) => log.event == 'camera.capture_local_saved'), isTrue);
    expect(logs.any((log) => log.event == 'camera.capture_success'), isTrue);
    expect(logs.every((log) => log.message.contains('sessionId=session-1')), isTrue);
  });

  test('camera metrics tracker marks previewed zero-capture sessions as abandoned', () async {
    final tempDir = await Directory.systemTemp.createTemp('joblens_camera_metrics_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final dbPath = p.join(tempDir.path, 'joblens.db');
    final database = await AppDatabase.open(databasePath: dbPath);
    addTearDown(database.close);
    final tracker = CameraMetricsTracker(database);

    await tracker.startSession(sessionId: 'session-2', platform: 'ios');
    await tracker.recordPreviewReady(
      sessionId: 'session-2',
      openToPreviewReadyMs: 301,
    );
    await tracker.recordCaptureFailed(
      sessionId: 'session-2',
      message: 'Capture failed: camera busy',
    );
    await tracker.completeSession(
      sessionId: 'session-2',
      abandoned: true,
      closeReason: 'session_closed',
    );

    final session = await tracker.getSession('session-2');
    expect(session, isNotNull);
    expect(session!.abandoned, isTrue);
    expect(session.hardFailureCount, 1);

    final summary = await tracker.getSummary();
    expect(summary.totalSessions, 1);
    expect(summary.previewReadySessions, 1);
    expect(summary.abandonedSessions, 1);
    expect(summary.captureAttempts, 0);
    expect(summary.captureSuccesses, 0);
    expect(summary.sessionAbandonRate, 1);

    final logs = await database.getAllSyncLogs();
    expect(logs.any((log) => log.event == 'camera.capture_failed'), isTrue);
    expect(logs.any((log) => log.event == 'camera.session_abandoned'), isTrue);
  });
}
