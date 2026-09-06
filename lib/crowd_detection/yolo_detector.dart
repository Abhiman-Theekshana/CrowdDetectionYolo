import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

class YoloDetector {
  Interpreter? _interpreter;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best.tflite',
      );
      _isLoaded = true;

      // DIAGNOSTIC — check console output
      print('INPUT shape: ${_interpreter!.getInputTensor(0).shape}');
      print('INPUT type: ${_interpreter!.getInputTensor(0).type}');
      print('OUTPUT shape: ${_interpreter!.getOutputTensor(0).shape}');
    } catch (e) {
      print('Error loading model: $e');
      _isLoaded = false;
    }
  }

  List<Detection> runInference(Float32List input, int inputWidth, int inputHeight) {
    if (_interpreter == null) return [];

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final outputSize = outputShape.reduce((a, b) => a * b);
    final output = Float32List(outputSize);

    _interpreter!.run(input, output);

    return _parseOutput(output, outputShape, inputWidth, inputHeight);
  }

  List<Detection> _parseOutput(Float32List output, List<int> shape, int inputWidth, int inputHeight) {
    final detections = <Detection>[];

    if (shape.length == 3) {
      final numFeatures = shape[1];
      final numDetections = shape[2];

      if (numFeatures == 5) {
        for (int i = 0; i < numDetections; i++) {
          final cx = output[0 * numDetections + i];
          final cy = output[1 * numDetections + i];
          final w = output[2 * numDetections + i];
          final h = output[3 * numDetections + i];
          final confidence = output[4 * numDetections + i];

          if (confidence > 0.4) {
            final left = (cx - w / 2) / inputWidth;
            final top = (cy - h / 2) / inputHeight;
            final right = (cx + w / 2) / inputWidth;
            final bottom = (cy + h / 2) / inputHeight;

            detections.add(Detection(
              left: left.clamp(0.0, 1.0),
              top: top.clamp(0.0, 1.0),
              right: right.clamp(0.0, 1.0),
              bottom: bottom.clamp(0.0, 1.0),
              confidence: confidence,
              classId: 0,
            ));
          }
        }
      }
    } else if (shape.length == 2) {
      final numDetections = shape[0];
      final featuresPerDetection = shape[1];

      if (featuresPerDetection >= 5) {
        for (int i = 0; i < numDetections; i++) {
          final offset = i * featuresPerDetection;
          final cx = output[offset];
          final cy = output[offset + 1];
          final w = output[offset + 2];
          final h = output[offset + 3];
          final confidence = output[offset + 4];

          if (confidence > 0.4) {
            final left = (cx - w / 2) / inputWidth;
            final top = (cy - h / 2) / inputHeight;
            final right = (cx + w / 2) / inputWidth;
            final bottom = (cy + h / 2) / inputHeight;

            detections.add(Detection(
              left: left.clamp(0.0, 1.0),
              top: top.clamp(0.0, 1.0),
              right: right.clamp(0.0, 1.0),
              bottom: bottom.clamp(0.0, 1.0),
              confidence: confidence,
              classId: 0,
            ));
          }
        }
      }
    }

    return _nonMaxSuppression(detections, 0.5);
  }

  List<Detection> _nonMaxSuppression(List<Detection> detections, double threshold) {
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));

    final kept = <Detection>[];
    for (final det in detections) {
      bool overlaps = false;
      for (final existing in kept) {
        final iou = _calculateIoU(det, existing);
        if (iou > threshold) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) kept.add(det);
    }
    return kept;
  }

  double _calculateIoU(Detection a, Detection b) {
    final x1 = a.left > b.left ? a.left : b.left;
    final y1 = a.top > b.top ? a.top : b.top;
    final x2 = a.right < b.right ? a.right : b.right;
    final y2 = a.bottom < b.bottom ? a.bottom : b.bottom;

    if (x2 <= x1 || y2 <= y1) return 0.0;

    final intersectionArea = (x2 - x1) * (y2 - y1);
    final aArea = (a.right - a.left) * (a.bottom - a.top);
    final bArea = (b.right - b.left) * (b.bottom - b.top);
    final unionArea = aArea + bArea - intersectionArea;

    return unionArea > 0 ? intersectionArea / unionArea : 0.0;
  }

  void dispose() {
    _interpreter?.close();
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
