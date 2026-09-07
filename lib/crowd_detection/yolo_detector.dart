import 'dart:math';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class YoloDetector {
  Interpreter? _interpreter;
  bool _isLoaded = false;
  int _inputSize = 320;

  bool get isLoaded => _isLoaded;
  int get inputSize => _inputSize;

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 4;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best.tflite',
        options: options,
      );

      final inputShape = _interpreter!.getInputTensor(0).shape;
      _inputSize = inputShape[1];
      _isLoaded = true;
    } catch (e) {
      _isLoaded = false;
      rethrow;
    }
  }

  Float32List preprocessImage(img.Image image) {
    final resized = img.copyResize(
      image,
      width: _inputSize,
      height: _inputSize,
    );

    final inputBuffer = Float32List(1 * _inputSize * _inputSize * 3);
    int bufferIndex = 0;

    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        inputBuffer[bufferIndex++] = pixel.r / 255.0;
        inputBuffer[bufferIndex++] = pixel.g / 255.0;
        inputBuffer[bufferIndex++] = pixel.b / 255.0;
      }
    }

    return inputBuffer;
  }

  List<Detection> runInference(Uint8List imageBytes) {
    if (_interpreter == null || !_isLoaded) return [];

    final image = img.decodeImage(imageBytes);
    if (image == null) return [];

    final inputBuffer = preprocessImage(image);

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final input = inputBuffer.reshape(inputShape);

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final outputSize = outputShape.reduce((a, b) => a * b);
    final output = List.filled(outputSize, 0.0).reshape(outputShape);

    _interpreter!.run(input, output);

    return _parseOutput(output, outputShape);
  }

  List<Detection> _parseOutput(List output, List<int> shape) {
    final detections = <Detection>[];

    if (shape.length == 3) {
      final numFeatures = shape[1];
      final numDetections = shape[2];

      if (numFeatures == 5) {
        for (int i = 0; i < numDetections; i++) {
          final cx = output[0][0][i];
          final cy = output[0][1][i];
          final w = output[0][2][i];
          final h = output[0][3][i];
          final confidence = output[0][4][i];

          if (confidence > 0.35) {
            final left = (cx - w / 2);
            final top = (cy - h / 2);
            final right = (cx + w / 2);
            final bottom = (cy + h / 2);

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
      } else if (numFeatures >= 6) {
        for (int i = 0; i < numDetections; i++) {
          final cx = output[0][0][i];
          final cy = output[0][1][i];
          final w = output[0][2][i];
          final h = output[0][3][i];
          final confidence = output[0][4][i];

          if (confidence > 0.35) {
            final left = (cx - w / 2);
            final top = (cy - h / 2);
            final right = (cx + w / 2);
            final bottom = (cy + h / 2);

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

      if (featuresPerDetection == 6) {
        for (int i = 0; i < numDetections; i++) {
          final offset = i * featuresPerDetection;
          final cx = output[0][offset];
          final cy = output[0][offset + 1];
          final w = output[0][offset + 2];
          final h = output[0][offset + 3];
          final confidence = output[0][offset + 4];

          if (confidence > 0.35) {
            final left = (cx - w / 2);
            final top = (cy - h / 2);
            final right = (cx + w / 2);
            final bottom = (cy + h / 2);

            detections.add(Detection(
              left: left.clamp(0.0, 1.0),
              top: top.clamp(0.0, 1.0),
              right: right.clamp(0.0, 1.0),
              bottom: bottom.clamp(0.0, 1.0),
              confidence: confidence,
              classId: output[0][offset + 5].toInt(),
            ));
          }
        }
      } else if (featuresPerDetection >= 84) {
        for (int i = 0; i < numDetections; i++) {
          final offset = i * featuresPerDetection;
          final cx = output[0][offset];
          final cy = output[0][offset + 1];
          final w = output[0][offset + 2];
          final h = output[0][offset + 3];

          double maxConf = 0;
          int maxClassId = 0;
          for (int c = 4; c < featuresPerDetection; c++) {
            if (output[0][offset + c] > maxConf) {
              maxConf = output[0][offset + c];
              maxClassId = c - 4;
            }
          }

          if (maxConf > 0.35) {
            final left = (cx - w / 2);
            final top = (cy - h / 2);
            final right = (cx + w / 2);
            final bottom = (cy + h / 2);

            detections.add(Detection(
              left: left.clamp(0.0, 1.0),
              top: top.clamp(0.0, 1.0),
              right: right.clamp(0.0, 1.0),
              bottom: bottom.clamp(0.0, 1.0),
              confidence: maxConf,
              classId: maxClassId,
            ));
          }
        }
      }
    }

    return _nonMaxSuppression(detections, 0.45);
  }

  List<Detection> _nonMaxSuppression(List<Detection> detections, double iouThreshold) {
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));

    final kept = <Detection>[];
    for (final det in detections) {
      bool overlaps = false;
      for (final existing in kept) {
        final iou = _calculateIoU(det, existing);
        if (iou > iouThreshold) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) kept.add(det);
    }
    return kept;
  }

  double _calculateIoU(Detection a, Detection b) {
    final x1 = max(a.left, b.left);
    final y1 = max(a.top, b.top);
    final x2 = min(a.right, b.right);
    final y2 = min(a.bottom, b.bottom);

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
