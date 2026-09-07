import '../crowd_detection/yolo_detector.dart';

class FrameAnalysisResult {
  final int frameNumber;
  final List<Detection> detections;
  final String? error;

  FrameAnalysisResult({
    required this.frameNumber,
    required this.detections,
    this.error,
  });

  bool get hasError => error != null;
  int get detectionCount => detections.length;

  double get highestConfidence {
    if (detections.isEmpty) return 0.0;
    double maxConf = 0.0;
    for (final d in detections) {
      if (d.confidence > maxConf) {
        maxConf = d.confidence;
      }
    }
    return maxConf;
  }
}
