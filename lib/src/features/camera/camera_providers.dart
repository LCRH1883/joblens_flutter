import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AvailableCamerasCatalog {
  Future<List<CameraDescription>>? _pendingLoad;
  List<CameraDescription> _cached = const [];

  Future<List<CameraDescription>> load() {
    if (_cached.isNotEmpty) {
      return Future.value(_cached);
    }
    final pendingLoad = _pendingLoad;
    if (pendingLoad != null) {
      return pendingLoad;
    }

    final loadFuture = availableCameras().then(
      (cameras) {
        _cached = List<CameraDescription>.unmodifiable(cameras);
        _pendingLoad = null;
        return _cached;
      },
      onError: (Object error, StackTrace stackTrace) {
        _pendingLoad = null;
        throw error;
      },
    );
    _pendingLoad = loadFuture;
    return loadFuture;
  }

  List<CameraDescription> get cached => _cached;
}

final availableCamerasProvider = Provider<AvailableCamerasCatalog>((ref) {
  return AvailableCamerasCatalog();
});
