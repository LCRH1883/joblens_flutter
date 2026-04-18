import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../app/joblens_store.dart';
import '../../core/ui/edge_swipe_back.dart';
import 'camera_providers.dart';
import 'camera_settings_repository.dart';

@Deprecated(
  'Legacy fallback camera implementation. Joblens uses JoblensCameraPage as the only active camera surface.',
)
class CameraCapturePage extends ConsumerStatefulWidget {
  const CameraCapturePage({super.key});

  @override
  ConsumerState<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends ConsumerState<CameraCapturePage>
    with WidgetsBindingObserver {
  static const _cameraInitializationTimeout = Duration(seconds: 8);

  CameraController? _controller;
  late final CameraSettingsRepository _settingsRepository;
  CameraSettings _settings = CameraSettings.defaults;
  List<CameraDescription> _availableCameras = const [];
  List<double> _zoomStops = const [1.0];
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  int _capturedCount = 0;
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isSwitchingLens = false;
  bool _isForeground = true;
  String? _error;
  Future<void> _pendingIngest = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsRepository = ref.read(cameraSettingsRepositoryProvider);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) {
      return;
    }
    final settings = await _settingsRepository.read();
    if (!mounted) {
      return;
    }

    _settings = settings;
    await _initializeCamera(preferredLens: settings.lensDirection);
  }

  Future<void> _initializeCamera({CameraLensDirection? preferredLens}) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isInitializing = true;
      _error = null;
    });

    final cameras = await ref
        .read(availableCamerasProvider)
        .load()
        .timeout(_cameraInitializationTimeout);
    if (cameras.isEmpty) {
      setState(() {
        _availableCameras = const [];
        _isInitializing = false;
        _error = 'No camera found on this device.';
      });
      return;
    }

    final camera = _selectCamera(
      cameras,
      preferredLens ?? _settings.lensDirection,
    );
    if (camera == null) {
      setState(() {
        _isInitializing = false;
        _error = 'Unable to select a usable camera.';
      });
      return;
    }

    final previous = _controller;
    final resolutionPreset = _settings.rapidCaptureMode
        ? ResolutionPreset.medium
        : ResolutionPreset.max;
    final controller = CameraController(
      camera,
      resolutionPreset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize().timeout(_cameraInitializationTimeout);
      if (!_isForeground) {
        await _disposeControllerSafely(controller);
        return;
      }
      var minZoom = 1.0;
      var maxZoom = 1.0;
      try {
        minZoom = await controller.getMinZoomLevel();
        maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {
        minZoom = 1.0;
        maxZoom = 1.0;
      }

      final clampedZoom = _settings.zoomStop.clamp(minZoom, maxZoom).toDouble();
      try {
        await controller.setZoomLevel(clampedZoom);
      } catch (_) {
        // Ignore zoom set failures for unsupported hardware.
      }

      var flashMode = _settings.flashMode;
      try {
        await controller.setFlashMode(flashMode);
      } catch (_) {
        flashMode = FlashMode.off;
        try {
          await controller.setFlashMode(flashMode);
        } catch (_) {
          // Ignore unsupported flash mode configurations.
        }
      }

      final zoomStops = _buildZoomStops(minZoom, maxZoom);

      if (!mounted) {
        await _disposeControllerSafely(controller);
        return;
      }

      setState(() {
        _availableCameras = cameras;
        _controller = controller;
        _isInitializing = false;
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _zoomStops = zoomStops;
        _settings = _settings.copyWith(
          lensDirection: camera.lensDirection,
          zoomStop: clampedZoom,
          flashMode: flashMode,
        );
      });

      await _disposeControllerSafely(previous);
      unawaited(_persistSettings());
    } catch (error) {
      await _disposeControllerSafely(controller);
      if (!mounted) {
        return;
      }
      setState(() {
        _availableCameras = cameras;
        _isInitializing = false;
        _error = _cameraErrorMessage(error);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    final isResuming = state == AppLifecycleState.resumed;
    _isForeground = isResuming;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _controller = null;
      if (controller != null) {
        unawaited(_disposeControllerSafely(controller));
      }
      return;
    }

    if (isResuming && mounted && controller == null && !_isInitializing) {
      unawaited(_initializeCamera(preferredLens: _settings.lensDirection));
    }
  }

  CameraDescription? _selectCamera(
    List<CameraDescription> cameras,
    CameraLensDirection preferred,
  ) {
    for (final camera in cameras) {
      if (camera.lensDirection == preferred) {
        return camera;
      }
    }

    for (final camera in cameras) {
      if (camera.lensDirection == CameraLensDirection.back) {
        return camera;
      }
    }
    return cameras.isNotEmpty ? cameras.first : null;
  }

  List<double> _buildZoomStops(double minZoom, double maxZoom) {
    final preferredStops = [0.5, 1.0, 2.0, 3.0, 5.0];
    final stops = <double>[];
    for (final raw in preferredStops) {
      final clamped = raw.clamp(minZoom, maxZoom).toDouble();
      final alreadyExists = stops.any(
        (value) => (value - clamped).abs() < 0.01,
      );
      if (!alreadyExists) {
        stops.add(clamped);
      }
    }
    if (stops.isEmpty) {
      stops.add(_settings.zoomStop.clamp(minZoom, maxZoom).toDouble());
    }
    return stops;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_persistSettings());
    final controller = _controller;
    _controller = null;
    unawaited(_disposeControllerSafely(controller));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isBusy = _isCapturing || _isSwitchingLens;

    return Scaffold(
      backgroundColor: Colors.black,
      body: EdgeSwipeBack(
        child: switch ((controller, _error, _isInitializing)) {
          (_, final String error, _) => _buildError(error),
          (null, _, true) => const Center(child: CircularProgressIndicator()),
          (null, _, false) => _buildError('Camera unavailable.'),
          _ => Stack(
            fit: StackFit.expand,
            children: [
              _buildPreview(controller!),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        _controlButton(
                          icon: Icons.arrow_back_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 10),
                        _controlButton(
                          icon: _flashIcon(_settings.flashMode),
                          onTap: isBusy ? null : _cycleFlashMode,
                        ),
                        const Spacer(),
                        _controlButton(
                          icon: Icons.cameraswitch_rounded,
                          onTap: isBusy || !_canSwitchLens ? null : _switchLens,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final stop in _zoomStops)
                              ChoiceChip(
                                selected:
                                    (_settings.zoomStop - stop).abs() < 0.05,
                                label: Text('${_formatZoom(stop)}x'),
                                onSelected: isBusy
                                    ? null
                                    : (_) => _setZoomStop(stop),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                              value: false,
                              label: Text('Single'),
                              icon: Icon(Icons.looks_one_rounded),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              label: Text('Rapid'),
                              icon: Icon(Icons.burst_mode_rounded),
                            ),
                          ],
                          selected: {_settings.rapidCaptureMode},
                          onSelectionChanged: isBusy
                              ? null
                              : (selection) => _setRapidMode(selection.first),
                          multiSelectionEnabled: false,
                          showSelectedIcon: false,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Spacer(),
                            Semantics(
                              button: true,
                              label: 'Capture photo',
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: isBusy ? null : _capture,
                                child: Container(
                                  width: 86,
                                  height: 86,
                                  padding: EdgeInsets.all(
                                    _isCapturing ? 18 : 12,
                                  ),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 4,
                                    ),
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _isCapturing
                                          ? Colors.white70
                                          : Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                        if (_settings.rapidCaptureMode) ...[
                          const SizedBox(height: 8),
                          Text(
                            '$_capturedCount captured',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (_isSwitchingLens)
                const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        },
      ),
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _isInitializing ? null : _bootstrap,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return CameraPreview(controller);
    }

    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: previewSize.height,
            height: previewSize.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return Ink(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: onTap == null
            ? const Color(0x55000000)
            : const Color(0x88000000),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }

  IconData _flashIcon(FlashMode mode) {
    return switch (mode) {
      FlashMode.auto => Icons.flash_auto_rounded,
      FlashMode.always => Icons.flash_on_rounded,
      FlashMode.torch => Icons.highlight_rounded,
      _ => Icons.flash_off_rounded,
    };
  }

  bool get _canSwitchLens {
    final hasBack = _availableCameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );
    final hasFront = _availableCameras.any(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
    return hasBack && hasFront;
  }

  Future<void> _switchLens() async {
    if (_isSwitchingLens) {
      return;
    }

    final targetLens = _settings.lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    setState(() {
      _isSwitchingLens = true;
      _settings = _settings.copyWith(lensDirection: targetLens);
    });

    try {
      await _initializeCamera(preferredLens: targetLens);
    } finally {
      if (mounted) {
        setState(() {
          _isSwitchingLens = false;
        });
      }
    }
  }

  Future<void> _cycleFlashMode() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    final modes = [
      FlashMode.off,
      FlashMode.auto,
      FlashMode.always,
      FlashMode.torch,
    ];
    final startIndex = math.max(modes.indexOf(_settings.flashMode), 0);

    for (var step = 1; step <= modes.length; step++) {
      final candidate = modes[(startIndex + step) % modes.length];
      try {
        await controller.setFlashMode(candidate);
        if (!mounted) {
          return;
        }
        setState(() {
          _settings = _settings.copyWith(flashMode: candidate);
        });
        unawaited(_persistSettings());
        return;
      } catch (_) {
        // Try the next mode until one succeeds.
      }
    }
  }

  Future<void> _setZoomStop(double stop) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final clamped = stop.clamp(_minZoom, _maxZoom).toDouble();
    try {
      await controller.setZoomLevel(clamped);
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = _settings.copyWith(zoomStop: clamped);
      });
      unawaited(_persistSettings());
    } catch (_) {
      // Ignore zoom errors on unsupported devices.
    }
  }

  void _setRapidMode(bool rapidMode) {
    if (_settings.rapidCaptureMode == rapidMode) {
      return;
    }

    setState(() {
      _settings = _settings.copyWith(rapidCaptureMode: rapidMode);
    });
    unawaited(_persistSettings());
    unawaited(_initializeCamera(preferredLens: _settings.lensDirection));
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final picture = await controller.takePicture();
      _queueIngest(File(picture.path));

      if (!mounted) {
        return;
      }

      if (_settings.rapidCaptureMode) {
        setState(() {
          _capturedCount += 1;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Captured $_capturedCount photo${_capturedCount == 1 ? '' : 's'}',
            ),
            duration: const Duration(milliseconds: 700),
          ),
        );
      } else {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Capture failed: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  void _queueIngest(File sourceFile) {
    if (!mounted) {
      return;
    }
    final store = ref.read(joblensStoreProvider);
    _pendingIngest = _pendingIngest.then((_) async {
      try {
        await store.ingestCapturedFile(sourceFile, processSyncNow: false);
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $error')));
      }
    });
  }

  String _formatZoom(double zoom) {
    final rounded = zoom.roundToDouble();
    if ((zoom - rounded).abs() < 0.05) {
      return rounded.toInt().toString();
    }
    return zoom.toStringAsFixed(1);
  }

  Future<void> _persistSettings() {
    return _settingsRepository.write(_settings);
  }

  Future<void> _disposeControllerSafely(CameraController? controller) async {
    if (controller == null) {
      return;
    }
    try {
      if (!controller.value.isInitialized) {
        return;
      }
      await controller.dispose();
    } on CameraException catch (error) {
      if (_isIgnorableAndroidDisposeError(error.description)) {
        debugPrint('Ignoring camera dispose race: ${error.description}');
        return;
      }
      rethrow;
    } on PlatformException catch (error) {
      if (_isIgnorableAndroidDisposeError(error.message)) {
        debugPrint('Ignoring camera dispose race: ${error.message}');
        return;
      }
      rethrow;
    }
  }

  bool _isIgnorableAndroidDisposeError(String? message) {
    if (message == null) {
      return false;
    }
    return message.contains('releaseFlutterSurfaceTexture() cannot be called');
  }

  String _cameraErrorMessage(Object error) {
    if (error is TimeoutException) {
      return 'Camera startup timed out. Make sure Joblens has camera permission and no other app is using the camera.';
    }

    final message = error.toString();
    if (message.contains('CameraAccessDenied')) {
      return 'Camera access was denied. Enable camera permission for Joblens in iPhone Settings.';
    }
    if (message.contains('CameraAccessRestricted')) {
      return 'Camera access is restricted on this device.';
    }
    if (message.contains('AudioAccessDenied')) {
      return 'Microphone access was denied.';
    }
    return 'Unable to initialize camera: $message';
  }
}
