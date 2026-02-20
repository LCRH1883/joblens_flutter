import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/joblens_store.dart';
import 'camera_providers.dart';

class CameraCapturePage extends ConsumerStatefulWidget {
  const CameraCapturePage({super.key});

  @override
  ConsumerState<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends ConsumerState<CameraCapturePage> {
  CameraController? _controller;
  bool _isCapturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = ref.read(availableCamerasProvider);
    if (cameras.isEmpty) {
      setState(() {
        _error = 'No camera found on this device.';
      });
      return;
    }

    final preferred = cameras
        .where((cam) => cam.lensDirection == CameraLensDirection.back)
        .toList();
    final camera = preferred.isNotEmpty ? preferred.first : cameras.first;

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller.initialize();

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      _controller = controller;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(title: const Text('Capture Photo')),
      body: switch ((controller, _error)) {
        (_, final String error) => Center(
          child: Text(error, textAlign: TextAlign.center),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        _ => Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller!),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: FilledButton.tonalIcon(
                  onPressed: _isCapturing ? null : _capture,
                  icon: const Icon(Icons.camera),
                  label: Text(_isCapturing ? 'Saving...' : 'Capture'),
                ),
              ),
            ),
          ],
        ),
      },
    );
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final picture = await controller.takePicture();
      await ref
          .read(joblensStoreProvider)
          .ingestCapturedFile(File(picture.path));
      if (mounted) {
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
}
