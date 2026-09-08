import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';

/// A raw YUV420 camera frame. Pixel conversion happens in the background
/// detection isolate — the UI thread only forwards these plane bytes.
class RawCameraFrame {
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  RawCameraFrame({
    required this.y,
    required this.u,
    required this.v,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });
}

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isStreaming = false;

  final StreamController<RawCameraFrame> _frameController =
      StreamController<RawCameraFrame>.broadcast();

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  Stream<RawCameraFrame> get frameStream => _frameController.stream;

  Future<void> initializeCameras() async {
    _cameras = await availableCameras();
  }

  /// Starts the camera. Defaults to [ResolutionPreset.low]: the model input
  /// is 320x320 regardless, so capturing higher than necessary only wastes
  /// per-pixel conversion work every frame.
  Future<void> startCamera(
      {ResolutionPreset resolution = ResolutionPreset.low}) async {
    if (_cameras.isEmpty) return;

    final backCamera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      backCamera,
      resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    _isInitialized = true;

    await _controller!.startImageStream((CameraImage image) {
      if (!_isStreaming) return;
      try {
        _frameController.add(RawCameraFrame(
          y: image.planes[0].bytes,
          u: image.planes[1].bytes,
          v: image.planes[2].bytes,
          width: image.width,
          height: image.height,
          yRowStride: image.planes[0].bytesPerRow,
          uvRowStride: image.planes[1].bytesPerRow,
          uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
        ));
      } catch (e) {
        // skip bad frame
      }
    });

    _isStreaming = true;
  }

  void stopCamera() {
    _isStreaming = false;
    _controller?.dispose();
    _controller = null;
    _isInitialized = false;
  }

  void dispose() {
    stopCamera();
    _frameController.close();
  }
}
