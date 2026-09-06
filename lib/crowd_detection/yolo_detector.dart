import 'dart:typed_data';
// ignore_for_file: avoid_print
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloDetector {
  late final YOLO _yolo;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<void> loadModel() async {
    try {
      _yolo = YOLO(
        modelPath: 'assets/models/best.onnx',
        task: YOLOTask.detect,
        useGpu: false,
      );
      _isLoaded = true;
    } catch (e) {
      print('Error loading model: $e');
      _isLoaded = false;
    }
  }

  Future<List<Detection>> predict(Uint8List imageBytes) async {
    if (!_isLoaded) return [];

    try {
      final results = await _yolo.predict(imageBytes);
      final detectionsRaw = results['detections'] as List<dynamic>? ?? [];

      return detectionsRaw
          .map((d) => Detection(
                left: (d['boundingBox']?['left'] as num?)?.toDouble() ?? 0,
                top: (d['boundingBox']?['top'] as num?)?.toDouble() ?? 0,
                right: (d['boundingBox']?['right'] as num?)?.toDouble() ?? 0,
                bottom: (d['boundingBox']?['bottom'] as num?)?.toDouble() ?? 0,
                confidence: (d['confidence'] as num?)?.toDouble() ?? 0,
                classId: (d['classIndex'] as num?)?.toInt() ?? 0,
              ))
          .where((d) => d.confidence > 0.4)
          .toList();
    } catch (e) {
      print('Prediction error: $e');
      return [];
    }
  }

  void dispose() {
    _yolo.dispose();
    _isLoaded = false;
  }
}

class Detection {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;
  final int classId;

  Detection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.confidence,
    required this.classId,
  });

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
}
