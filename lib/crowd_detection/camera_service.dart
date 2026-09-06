import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';

class CameraFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  CameraFrame({required this.bytes, required this.width, required this.height});
}

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  StreamController<CameraFrame>? _frameStreamController;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  Stream<CameraFrame> get imageStream => _frameStreamController!.stream;

  Future<void> initializeCameras() async {
    _cameras = await availableCameras();
  }

  Future<void> startCamera({
    CameraLensDirection direction = CameraLensDirection.back,
    ResolutionPreset resolution = ResolutionPreset.medium,
  }) async {
    if (_cameras.isEmpty) {
      await initializeCameras();
    }

    final camera = _cameras.firstWhere(
      (c) => c.lensDirection == direction,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      camera,
      resolution,
      enableAudio: false,
    );

    await _controller!.initialize();
    _isInitialized = true;

    _frameStreamController = StreamController<CameraFrame>.broadcast();

    _controller!.startImageStream((CameraImage image) {
      if (_frameStreamController != null && !_frameStreamController!.isClosed) {
        final bytes = _convertCameraImage(image);
        if (bytes != null) {
          _frameStreamController!.add(CameraFrame(
            bytes: bytes,
            width: image.width,
            height: image.height,
          ));
        }
      }
    });
  }

  Uint8List? _convertCameraImage(CameraImage image) {
    try {
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

          final yVal = yPlane[yIndex];
          final uVal = uPlane[uvIndex];
          final vVal = vPlane[uvIndex];

          final c = (yVal - 16).clamp(0, 255);
          final d = (uVal - 128).clamp(-128, 127);
          final e = (vVal - 128).clamp(-128, 127);

          int r = ((c + ((e * 296) >> 8)) * 255 / 279).round();
          int g = ((c - ((d * 100) >> 8) - ((e * 146) >> 8)) * 255 / 448).round();
          int b = ((c + ((d * 401) >> 8)) * 255 / 514).round();

          rgbBytes[rgbIndex++] = r.clamp(0, 255);
          rgbBytes[rgbIndex++] = g.clamp(0, 255);
          rgbBytes[rgbIndex++] = b.clamp(0, 255);
        }
      }

      return rgbBytes;
    } catch (e) {
      return null;
    }
  }

  Future<void> stopCamera() async {
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    await _frameStreamController?.close();
    _frameStreamController = null;
  }

  void dispose() {
    _controller?.dispose();
    _frameStreamController?.close();
  }
}
