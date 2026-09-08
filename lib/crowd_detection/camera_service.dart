import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'lens_selector.dart';

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

/// Describes which camera path was selected at startup.
enum LensMode { main, ultraWideLens, ultraWideZoom }

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isStreaming = false;

  /// Current lens mode in use.
  LensMode _activeLensMode = LensMode.main;
  LensMode get activeLensMode => _activeLensMode;

  /// Human-readable label for the active lens mode, shown in the HUD.
  String get lensModeLabel {
    switch (_activeLensMode) {
      case LensMode.main:
        return 'main';
      case LensMode.ultraWideLens:
        return 'ultra-wide (lens)';
      case LensMode.ultraWideZoom:
        return 'ultra-wide (zoom)';
    }
  }

  final StreamController<RawCameraFrame> _frameController =
      StreamController<RawCameraFrame>.broadcast();

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;

  Stream<RawCameraFrame> get frameStream => _frameController.stream;

  Future<void> initializeCameras() async {
    _cameras = await availableCameras();
  }

  /// Starts the camera with the given [useUltraWide] setting.
  ///
  /// 1. If [useUltraWide] is false → default back camera at low resolution.
  /// 2. If [useUltraWide] is true → try [LensSelector.detectUltraWide] for a
  ///    distinct ultra-wide CameraDescription.  If found, use it directly.
  /// 3. If not found, fall back to the default back camera and set zoom to the
  ///    device's minimum zoom level (near 0.6x on the S22).
  Future<void> startCamera({
    ResolutionPreset resolution = ResolutionPreset.low,
    bool useUltraWide = false,
  }) async {
    if (_cameras.isEmpty) return;

    CameraDescription selectedCamera;
    _activeLensMode = LensMode.main;

    if (useUltraWide) {
      // Attempt 1: find a physically distinct ultra-wide lens via focal length.
      final ultraWide = await LensSelector.detectUltraWide();
      if (ultraWide != null) {
        selectedCamera = ultraWide;
        _activeLensMode = LensMode.ultraWideLens;
        debugPrint('[Lens] Using distinct ultra-wide lens: ${ultraWide.name}');
      } else {
        // Attempt 2: zoom fallback — use the default back camera and dial
        // the zoom level down after initialization.
        selectedCamera = _cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => _cameras.first,
        );
        _activeLensMode = LensMode.ultraWideZoom;
        debugPrint('[Lens] No distinct ultra-wide lens; using zoom fallback');
      }
    } else {
      selectedCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      _activeLensMode = LensMode.main;
    }

    _controller = CameraController(
      selectedCamera,
      resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    _isInitialized = true;

    // Apply zoom fallback if requested and no distinct lens was found.
    if (_activeLensMode == LensMode.ultraWideZoom) {
      await _applyZoomFallback();
    }

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

  /// Sets the zoom level to the device's minimum if it's below 1.0
  /// (i.e. the camera supports sub-1.0x ultra-wide zoom).
  Future<void> _applyZoomFallback() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      final minZoom = await ctrl.getMinZoomLevel();
      final maxZoom = await ctrl.getMaxZoomLevel();
      debugPrint('[Lens] Zoom range: min=$minZoom, max=$maxZoom');
      if (minZoom < 1.0) {
        // Clamp to the minimum supported value (may be exactly 0.6 on S22).
        await ctrl.setZoomLevel(minZoom);
        debugPrint('[Lens] Applied zoom fallback: setZoomLevel($minZoom)');
      } else {
        debugPrint(
            '[Lens] Min zoom is $minZoom (>= 1.0) — zoom fallback unavailable');
        _activeLensMode = LensMode.main;
      }
    } catch (e) {
      debugPrint('[Lens] Zoom fallback failed: $e — falling back to main');
      _activeLensMode = LensMode.main;
    }
  }

  void stopCamera() {
    _isStreaming = false;
    _controller?.dispose();
    _controller = null;
    _isInitialized = false;
  }

  /// Restarts the camera with a new ultra-wide setting.
  Future<void> restartCamera({
    ResolutionPreset resolution = ResolutionPreset.low,
    bool useUltraWide = false,
  }) async {
    stopCamera();
    await startCamera(resolution: resolution, useUltraWide: useUltraWide);
  }

  void dispose() {
    stopCamera();
    _frameController.close();
  }
}
