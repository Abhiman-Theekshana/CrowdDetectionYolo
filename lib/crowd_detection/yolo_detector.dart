import 'dart:math';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class LetterboxResult {
  final img.Image paddedImage;
  final double scale;
  final int padX;
  final int padY;

  LetterboxResult({
    required this.paddedImage,
    required this.scale,
    required this.padX,
    required this.padY,
  });
}

class StagedInference {
  final List<Detection> detections;
  final int rawCount;
  final double preMs;
  final double inferMs;
  final double postMs;

  const StagedInference({
    required this.detections,
    required this.rawCount,
    required this.preMs,
    required this.inferMs,
    required this.postMs,
  });
}

class YoloDetector {
  Interpreter? _interpreter;
  bool _isLoaded = false;
  int _inputSize = 320;
  double confidenceThreshold = 0.35;
  double iouThreshold = 0.45;

  /// Which acceleration path is actually in use: 'gpu-fp16', 'nnapi' or 'cpu'.
  String activeDelegate = 'cpu';

  /// Average inference ms per delegate from the last benchmark run
  /// (only populated by [loadModelWithBenchmark]).
  Map<String, double> benchmarkMs = {};

  // Letterbox geometry of the last preprocessed frame, for mapping
  // detection boxes from padded-image space back to original-frame space.
  double _lastScale = 1.0;
  int _lastPadX = 0;
  int _lastPadY = 0;
  int _lastOriginalWidth = 1;
  int _lastOriginalHeight = 1;

  bool get isLoaded => _isLoaded;
  int get inputSize => _inputSize;

  /// Returns the interpreter's input tensor shape (e.g. `[1, 3, 320, 320]`).
  List<int> get inputShape =>
      _interpreter?.getInputTensor(0).shape ?? [1, 3, _inputSize, _inputSize];

  /// Builds interpreter options for a named delegate candidate.
  /// Returns null if that candidate is unavailable (GPU delegate missing).
  InterpreterOptions? _optionsFor(String name) {
    switch (name) {
      case 'gpu-fp16':
        try {
          final options = InterpreterOptions()..threads = 4;
          options.addDelegate(GpuDelegateV2(
            options: GpuDelegateOptionsV2(isPrecisionLossAllowed: true),
          ));
          return options;
        } catch (_) {
          return null;
        }
      case 'nnapi':
        final options = InterpreterOptions()..threads = 4;
        options.useNnApiForAndroid = true;
        return options;
      default:
        return InterpreterOptions()..threads = 4;
    }
  }

  void _readInputSize() {
    final inputShape = _interpreter!.getInputTensor(0).shape;
    if (inputShape.length == 4) {
      if (inputShape[1] == 3) {
        _inputSize = inputShape[2]; // NCHW format [1, 3, 320, 320]
      } else {
        _inputSize = inputShape[1]; // NHWC format [1, 320, 320, 3]
      }
    } else {
      _inputSize = 320;
    }
  }

  Future<void> loadModel() async {
    // Ordered fallback: GPU (FP16) -> NNAPI -> CPU. First one that
    // initializes successfully wins.
    const candidates = ['gpu-fp16', 'nnapi', 'cpu'];
    Object? lastError;
    for (final name in candidates) {
      final options = _optionsFor(name);
      if (options == null) continue;
      try {
        _interpreter = await Interpreter.fromAsset(
          'assets/models/best.tflite',
          options: options,
        );
        activeDelegate = name;
        _readInputSize();
        _isLoaded = true;
        return;
      } catch (e) {
        lastError = e;
      }
    }
    _isLoaded = false;
    throw lastError ?? StateError('Failed to load model with any delegate');
  }

  /// Loads the model from raw bytes, benchmarks every viable delegate with
  /// real dummy inferences, and keeps the empirically fastest interpreter.
  /// Designed for the background detection isolate (interpreters cannot be
  /// shared across isolates). Populates [activeDelegate] and [benchmarkMs].
  Future<void> loadModelWithBenchmark(Uint8List modelBytes) async {
    const candidates = ['gpu-fp16', 'nnapi', 'cpu'];
    final timings = <String, double>{};
    Interpreter? best;
    String bestName = 'cpu';

    for (final name in candidates) {
      final options = _optionsFor(name);
      if (options == null) continue;
      Interpreter? candidate;
      try {
        candidate = Interpreter.fromBuffer(modelBytes, options: options);
        final avgMs = _timeDummyRuns(candidate, runs: 3);
        timings[name] = avgMs;
        if (best == null || avgMs < timings[bestName]!) {
          best?.close();
          best = candidate;
          bestName = name;
          candidate = null; // ownership transferred to best
        }
      } catch (_) {
        // Candidate unavailable/failed — skip it.
      } finally {
        candidate?.close();
      }
    }

    if (best == null) {
      throw StateError('Failed to load model with any delegate');
    }
    _interpreter = best;
    activeDelegate = bestName;
    benchmarkMs = timings;
    _readInputSize();
    _isLoaded = true;
  }

  /// Runs [runs] timed dummy inferences (after 1 warmup) and returns the
  /// average inference time in milliseconds.
  double _timeDummyRuns(Interpreter interpreter, {int runs = 3}) {
    final inputShape = interpreter.getInputTensor(0).shape;
    final inputSize = inputShape.reduce((a, b) => a * b);
    final input = Float32List(inputSize).reshape(inputShape);

    final outputShape = interpreter.getOutputTensor(0).shape;
    final outputSize = outputShape.reduce((a, b) => a * b);
    final output = List.filled(outputSize, 0.0).reshape(outputShape);

    interpreter.run(input, output); // warmup (delegate compilation etc.)
    final sw = Stopwatch()..start();
    for (int i = 0; i < runs; i++) {
      interpreter.run(input, output);
    }
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0 / runs;
  }

  LetterboxResult letterboxResize(img.Image image, int targetSize) {
    final originalWidth = image.width;
    final originalHeight = image.height;

    // Scale so the LONGER side fits within targetSize, preserving aspect ratio.
    final scale = (targetSize / originalWidth < targetSize / originalHeight)
        ? targetSize / originalWidth
        : targetSize / originalHeight;

    final scaledWidth = (originalWidth * scale).round();
    final scaledHeight = (originalHeight * scale).round();

    final resized = img.copyResize(
      image,
      width: scaledWidth,
      height: scaledHeight,
    );

    // Create a targetSize x targetSize canvas filled with grey
    // (114,114,114 — standard YOLO padding).
    final padded = img.Image(width: targetSize, height: targetSize);
    img.fill(padded, color: img.ColorRgb8(114, 114, 114));

    // Center the resized image on the padded canvas.
    final padX = (targetSize - scaledWidth) ~/ 2;
    final padY = (targetSize - scaledHeight) ~/ 2;

    img.compositeImage(padded, resized, dstX: padX, dstY: padY);

    return LetterboxResult(
      paddedImage: padded,
      scale: scale,
      padX: padX,
      padY: padY,
    );
  }

  /// Maps a box from 0-1 normalized letterboxed-image space back to 0-1
  /// normalized coordinates in the ORIGINAL frame.
  List<double> _unletterbox(
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final correctedLeft =
        (left * _inputSize - _lastPadX) / _lastScale / _lastOriginalWidth;
    final correctedTop =
        (top * _inputSize - _lastPadY) / _lastScale / _lastOriginalHeight;
    final correctedRight =
        (right * _inputSize - _lastPadX) / _lastScale / _lastOriginalWidth;
    final correctedBottom =
        (bottom * _inputSize - _lastPadY) / _lastScale / _lastOriginalHeight;
    return [correctedLeft, correctedTop, correctedRight, correctedBottom];
  }

  Float32List preprocessImage(img.Image image) {
    _lastOriginalWidth = image.width;
    _lastOriginalHeight = image.height;

    final letterboxResult = letterboxResize(image, _inputSize);
    final resized = letterboxResult.paddedImage;

    // Store geometry so detection boxes can be mapped back afterwards.
    _lastScale = letterboxResult.scale;
    _lastPadX = letterboxResult.padX;
    _lastPadY = letterboxResult.padY;

    final inputShape = _interpreter!.getInputTensor(0).shape;
    final isNCHW = inputShape.length == 4 && inputShape[1] == 3;
    final totalPixels = _inputSize * _inputSize;
    final inputBuffer = Float32List(1 * 3 * totalPixels);

    if (isNCHW) {
      // NCHW format: [1, 3, H, W] -> R plane, G plane, B plane
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          final pixelIndex = y * _inputSize + x;
          inputBuffer[pixelIndex] = pixel.r / 255.0;
          inputBuffer[totalPixels + pixelIndex] = pixel.g / 255.0;
          inputBuffer[2 * totalPixels + pixelIndex] = pixel.b / 255.0;
        }
      }
    } else {
      // NHWC format: [1, H, W, 3] -> Interleaved R, G, B
      int bufferIndex = 0;
      for (int y = 0; y < _inputSize; y++) {
        for (int x = 0; x < _inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          inputBuffer[bufferIndex++] = pixel.r / 255.0;
          inputBuffer[bufferIndex++] = pixel.g / 255.0;
          inputBuffer[bufferIndex++] = pixel.b / 255.0;
        }
      }
    }

    return inputBuffer;
  }

  List<Detection> runInference(Uint8List imageBytes, {int? width, int? height}) {
    if (_interpreter == null || !_isLoaded) return [];

    img.Image? image;
    if (width != null && height != null) {
      // Raw RGB bytes (e.g. from the camera): construct directly, no decode.
      try {
        image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: imageBytes.buffer,
          order: img.ChannelOrder.rgb,
        );
      } catch (_) {
        return [];
      }
    } else {
      // Encoded image bytes (e.g. PNG video thumbnails): decode first.
      image = img.decodeImage(imageBytes);
    }
    if (image == null) return [];

    return runInferenceFromImage(image).detections;
  }

  /// Runs the full pipeline on an already-decoded image and reports per-stage
  /// timings (pre / inference / post) in milliseconds.
  StagedInference runInferenceFromImage(img.Image image) {
    final pre = Stopwatch()..start();
    final inputBuffer = preprocessImage(image);
    final inputShape = _interpreter!.getInputTensor(0).shape;
    final input = inputBuffer.reshape(inputShape);
    pre.stop();

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    final outputSize = outputShape.reduce((a, b) => a * b);
    final output = List.filled(outputSize, 0.0).reshape(outputShape);

    final infer = Stopwatch()..start();
    _interpreter!.run(input, output);
    infer.stop();

    final post = Stopwatch()..start();
    final (rawCount, detections) = _parseOutput(output, outputShape);
    post.stop();

    return StagedInference(
      detections: detections,
      rawCount: rawCount,
      preMs: pre.elapsedMicroseconds / 1000.0,
      inferMs: infer.elapsedMicroseconds / 1000.0,
      postMs: post.elapsedMicroseconds / 1000.0,
    );
  }

  (int, List<Detection>) _parseOutput(List output, List<int> shape) {
    final detections = <Detection>[];
    if (shape.length == 3) {
      final numFeatures = shape[1];
      final numDetections = shape[2];

      if (numFeatures == 5) {
        for (int i = 0; i < numDetections; i++) {
          final rawCx = (output[0][0][i] as num).toDouble();
          final rawCy = (output[0][1][i] as num).toDouble();
          final rawW = (output[0][2][i] as num).toDouble();
          final rawH = (output[0][3][i] as num).toDouble();
          final confidence = (output[0][4][i] as num).toDouble();

          if (confidence > confidenceThreshold) {
            final cx = rawCx > 1.0 ? rawCx / _inputSize : rawCx;
            final cy = rawCy > 1.0 ? rawCy / _inputSize : rawCy;
            final w = rawW > 1.0 ? rawW / _inputSize : rawW;
            final h = rawH > 1.0 ? rawH / _inputSize : rawH;

            final lbLeft = (cx - w / 2);
            final lbTop = (cy - h / 2);
            final lbRight = (cx + w / 2);
            final lbBottom = (cy + h / 2);

            final ub = _unletterbox(lbLeft, lbTop, lbRight, lbBottom);

            detections.add(Detection(
              left: ub[0].clamp(0.0, 1.0),
              top: ub[1].clamp(0.0, 1.0),
              right: ub[2].clamp(0.0, 1.0),
              bottom: ub[3].clamp(0.0, 1.0),
              confidence: confidence,
              classId: 0,
            ));
          }
        }
      } else if (numFeatures >= 6) {
        for (int i = 0; i < numDetections; i++) {
          final rawCx = (output[0][0][i] as num).toDouble();
          final rawCy = (output[0][1][i] as num).toDouble();
          final rawW = (output[0][2][i] as num).toDouble();
          final rawH = (output[0][3][i] as num).toDouble();
          final confidence = (output[0][4][i] as num).toDouble();

          if (confidence > confidenceThreshold) {
            final cx = rawCx > 1.0 ? rawCx / _inputSize : rawCx;
            final cy = rawCy > 1.0 ? rawCy / _inputSize : rawCy;
            final w = rawW > 1.0 ? rawW / _inputSize : rawW;
            final h = rawH > 1.0 ? rawH / _inputSize : rawH;

            final lbLeft = (cx - w / 2);
            final lbTop = (cy - h / 2);
            final lbRight = (cx + w / 2);
            final lbBottom = (cy + h / 2);

            final ub = _unletterbox(lbLeft, lbTop, lbRight, lbBottom);

            detections.add(Detection(
              left: ub[0].clamp(0.0, 1.0),
              top: ub[1].clamp(0.0, 1.0),
              right: ub[2].clamp(0.0, 1.0),
              bottom: ub[3].clamp(0.0, 1.0),
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

          if (confidence > confidenceThreshold) {
            final lbLeft = (cx - w / 2);
            final lbTop = (cy - h / 2);
            final lbRight = (cx + w / 2);
            final lbBottom = (cy + h / 2);

            final ub = _unletterbox(lbLeft, lbTop, lbRight, lbBottom);

            detections.add(Detection(
              left: ub[0].clamp(0.0, 1.0),
              top: ub[1].clamp(0.0, 1.0),
              right: ub[2].clamp(0.0, 1.0),
              bottom: ub[3].clamp(0.0, 1.0),
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

          if (maxConf > confidenceThreshold) {
            final lbLeft = (cx - w / 2);
            final lbTop = (cy - h / 2);
            final lbRight = (cx + w / 2);
            final lbBottom = (cy + h / 2);

            final ub = _unletterbox(lbLeft, lbTop, lbRight, lbBottom);

            detections.add(Detection(
              left: ub[0].clamp(0.0, 1.0),
              top: ub[1].clamp(0.0, 1.0),
              right: ub[2].clamp(0.0, 1.0),
              bottom: ub[3].clamp(0.0, 1.0),
              confidence: maxConf,
              classId: maxClassId,
            ));
          }
        }
      }
    }

    final rawCount = detections.length;
    return (rawCount, _nonMaxSuppression(detections, iouThreshold));
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
