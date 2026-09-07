import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';

class CameraFrame {
  final Uint8List bytes;
  final int width;
  final int height;

  CameraFrame({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isStreaming = false;

  final StreamController<CameraFrame> _frameController =
      StreamController<CameraFrame>.broadcast();

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  Stream<CameraFrame> get frameStream => _frameController.stream;

  Future<void> initializeCameras() async {
    _cameras = await availableCameras();
  }

  Future<void> startCamera({ResolutionPreset resolution = ResolutionPreset.medium}) async {
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
      _processCameraImage(image);
    });

    _isStreaming = true;
  }

  void _processCameraImage(CameraImage image) {
    try {
      final rgbBytes = _convertYUV420ToRGB(image);
      _frameController.add(CameraFrame(
        bytes: rgbBytes,
        width: image.planes[0].width ?? image.width,
        height: image.planes[0].height ?? image.height,
      ));
    } catch (e) {
      // skip bad frame
    }
  }

  Uint8List _convertYUV420ToRGB(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    final yRowStride = image.planes[0].bytesPerRow;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    final rgbBytes = Uint8List(width * height * 3);
    int rgbIndex = 0;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

        final yValue = yPlane[yIndex];
        final uValue = uPlane[uvIndex];
        final vValue = vPlane[uvIndex];

        int r = (yValue + 1.370705 * (vValue - 128)).round();
        int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128)).round();
        int b = (yValue + 1.732446 * (uValue - 128)).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        rgbBytes[rgbIndex++] = r;
        rgbBytes[rgbIndex++] = g;
        rgbBytes[rgbIndex++] = b;
      }
    }

    return rgbBytes;
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
