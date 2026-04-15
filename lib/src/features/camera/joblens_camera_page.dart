import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import '../../core/models/capture_target_preference.dart';
import '../../core/models/project.dart';
import 'camera_metrics_tracker.dart';
import 'camera_settings_repository.dart';
import 'native_camera_bridge.dart';

class JoblensCameraPage extends ConsumerStatefulWidget {
  const JoblensCameraPage({super.key, this.onSessionClosed});

  final VoidCallback? onSessionClosed;

  @override
  ConsumerState<JoblensCameraPage> createState() => _JoblensCameraPageState();
}

class _JoblensCameraPageState extends ConsumerState<JoblensCameraPage> {
  static const _bridge = NativeCameraBridge();

  StreamSubscription<NativeCameraSessionEvent>? _eventSubscription;
  String? _error;
  bool _launching = false;
  String? _sessionId;
  int _capturedCount = 0;
  bool _previewReady = false;
  int _captureAttemptCount = 0;
  String? _closeReason;
  bool _sessionFinished = false;

  @override
  void initState() {
    super.initState();
    if (_supportsNativeCamera) {
      _eventSubscription = _bridge.events().listen(_handleNativeEvent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openNativeCamera());
      });
    }
  }

  bool get _supportsNativeCamera => Platform.isAndroid || Platform.isIOS;

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.photo_camera_outlined,
                  color: Colors.white,
                  size: 56,
                ),
                const SizedBox(height: 20),
                Text(
                  _launching
                      ? 'Opening camera...'
                      : _capturedCount > 0
                      ? '$_capturedCount photo${_capturedCount == 1 ? '' : 's'} captured'
                      : 'Camera closed',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _launching ? null : _openNativeCamera,
                  icon: const Icon(Icons.open_in_full_rounded),
                  label: const Text('Open camera'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openNativeCamera() async {
    if (!mounted || _launching) {
      return;
    }

    final store = ref.read(joblensStoreProvider);
    final projects = store.projects;
    if (projects.isEmpty) {
      setState(() {
        _error = 'No project available for camera capture.';
      });
      return;
    }

    final settingsRepository = ref.read(cameraSettingsRepositoryProvider);
    final settings = await settingsRepository.read();
    final config = _buildLaunchConfig(store, projects, settings);
    final nextSessionId = config.sessionId;
    final tracker = ref.read(cameraMetricsTrackerProvider);

    setState(() {
      _launching = true;
      _error = null;
      _capturedCount = 0;
      _sessionId = nextSessionId;
      _previewReady = false;
      _captureAttemptCount = 0;
      _closeReason = null;
      _sessionFinished = false;
    });

    try {
      await tracker.startSession(
        sessionId: nextSessionId,
        platform: Platform.operatingSystem,
      );
      await _bridge.openCamera(config);
    } catch (error) {
      await tracker.recordOpenFailed(
        sessionId: nextSessionId,
        message: 'Native camera failed to open: $error',
      );
      await tracker.completeSession(
        sessionId: nextSessionId,
        abandoned: false,
        closeReason: 'open_failed',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _launching = false;
        _error = 'Native camera failed to open: $error';
        _sessionId = null;
        _sessionFinished = true;
      });
    }
  }

  NativeCameraLaunchConfig _buildLaunchConfig(
    JoblensStore store,
    List<Project> projects,
    CameraSettings settings,
  ) {
    final launchSettings = settings.normalizedForLaunch();
    final resolved = store.resolveCaptureTarget();
    final inbox = projects.firstWhere(
      (project) => project.name == 'Inbox',
      orElse: () => projects.first,
    );
    final fixedProjects =
        projects
            .where((project) => project.id != inbox.id)
            .toList(growable: false)
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    final targets = <NativeCameraTargetOption>[
      NativeCameraTargetOption(
        mode: CaptureTargetMode.inbox,
        label: 'Inbox',
        resolvedProjectId: inbox.id,
        resolvedProjectName: inbox.name,
      ),
      for (final project in fixedProjects)
        NativeCameraTargetOption(
          mode: CaptureTargetMode.fixedProject,
          label: project.name,
          resolvedProjectId: project.id,
          resolvedProjectName: project.name,
          fixedProjectId: project.id,
        ),
    ];
    final normalizedCurrentMode = resolved.projectId == inbox.id
        ? CaptureTargetMode.inbox
        : CaptureTargetMode.fixedProject;

    return NativeCameraLaunchConfig(
      sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
      currentMode: normalizedCurrentMode,
      currentProjectId: resolved.projectId,
      currentProjectName: resolved.projectName,
      targets: targets,
      settings: launchSettings,
    );
  }

  Future<void> _handleNativeEvent(NativeCameraSessionEvent event) async {
    if (!mounted) {
      return;
    }
    if (_sessionId != null &&
        event.sessionId != null &&
        event.sessionId != _sessionId) {
      return;
    }

    final store = ref.read(joblensStoreProvider);
    final tracker = ref.read(cameraMetricsTrackerProvider);
    final settingsRepository = ref.read(cameraSettingsRepositoryProvider);
    final activeSessionId = _sessionId;
    if (activeSessionId == null) {
      return;
    }

    switch (event.type) {
      case NativeCameraEventType.previewReady:
        _previewReady = true;
        await tracker.recordPreviewReady(
          sessionId: activeSessionId,
          openToPreviewReadyMs: event.openDurationMs,
        );
        break;
      case NativeCameraEventType.captureStarted:
        _captureAttemptCount += 1;
        await tracker.recordCaptureStarted(
          sessionId: activeSessionId,
          photoId: event.photoId,
        );
        break;
      case NativeCameraEventType.targetChanged:
        final targetMode = event.targetMode;
        if (targetMode != null) {
          await store.updateCaptureTargetPreference(
            mode: targetMode,
            fixedProjectId: event.fixedProjectId,
          );
        }
        break;
      case NativeCameraEventType.lensSwitchCompleted:
        await tracker.recordLensSwitchCompleted(
          sessionId: activeSessionId,
          durationMs: event.durationMs,
        );
        break;
      case NativeCameraEventType.lensSwitchFailed:
        _closeReason ??= 'lens_switch_failed';
        await tracker.recordLensSwitchFailed(
          sessionId: activeSessionId,
          durationMs: event.durationMs,
          message: event.message ?? 'Lens switch failed.',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = event.message ?? 'Lens switch failed.';
        });
        break;
      case NativeCameraEventType.targetPickerOpened:
        await tracker.recordTargetPickerOpened(
          sessionId: activeSessionId,
          durationMs: event.durationMs,
        );
        break;
      case NativeCameraEventType.targetPickerFailed:
        await tracker.recordTargetPickerFailed(
          sessionId: activeSessionId,
          message: event.message ?? 'Capture target picker failed.',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = event.message ?? 'Capture target picker failed.';
        });
        break;
      case NativeCameraEventType.captureSaved:
        final localPath = event.localPath;
        final targetProjectId = event.targetProjectId;
        if (localPath == null || targetProjectId == null) {
          break;
        }
        await tracker.recordCaptureLocalSaved(
          sessionId: activeSessionId,
          photoId: event.photoId,
          captureLocalSaveMs: event.captureDurationMs,
        );
        final ingested = await store.ingestCapturedFile(
          File(localPath),
          projectId: targetProjectId,
          processSyncNow: false,
        );
        if (!ingested) {
          await tracker.recordIngestFailed(
            sessionId: activeSessionId,
            photoId: event.photoId,
            message: 'Capture ingest failed: local ingest did not complete.',
          );
          if (!mounted) {
            return;
          }
          setState(() {
            _error = 'Capture ingest failed.';
          });
          break;
        }
        await tracker.recordCaptureSuccess(
          sessionId: activeSessionId,
          photoId: event.photoId,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _capturedCount += 1;
        });
        break;
      case NativeCameraEventType.captureFailed:
        await tracker.recordCaptureFailed(
          sessionId: activeSessionId,
          photoId: event.photoId,
          message: event.message ?? 'Capture failed.',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _error = event.message ?? 'Capture failed.';
        });
        break;
      case NativeCameraEventType.sessionClosed:
        if (event.settings != null) {
          await settingsRepository.write(event.settings!);
        }
        if (!_sessionFinished) {
          final reason = _closeReason ?? 'session_closed';
          await tracker.completeSession(
            sessionId: activeSessionId,
            abandoned: _previewReady && _captureAttemptCount == 0,
            closeReason: reason,
          );
          _sessionFinished = true;
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _launching = false;
          _sessionId = null;
          _previewReady = false;
          _captureAttemptCount = 0;
          _closeReason = null;
        });
        widget.onSessionClosed?.call();
        break;
    }
  }
}
