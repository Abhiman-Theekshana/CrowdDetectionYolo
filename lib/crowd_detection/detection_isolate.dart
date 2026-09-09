import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'yolo_detector.dart';

/// Result of one worker-processed frame, sent back to the UI isolate.
class WorkerResult {
  final int id;
  final List<Detection> detections;
  final int rawCount;
  final double yuvMs;
  final double letterboxMs;
  final double inferMs;
  final double postMs;
  final double isolateSendMs;
  final double isolateReceiveMs;
  final String? error;

  WorkerResult({
    required this.id,
    required this.detections,
    required this.rawCount,
    required this.yuvMs,
    required this.letterboxMs,
    required this.inferMs,
    required this.postMs,
    required this.isolateSendMs,
    required this.isolateReceiveMs,
    this.error,
  });
}

/// YUV420 (planar) -> interleaved RGB conversion. Runs inside the worker
/// isolate so the UI thread never does per-pixel work.
Uint8List convertYUV420ToRGB(
  Uint8List yPlane,
  Uint8List uPlane,
  Uint8List vPlane,
  int width,
  int height,
  int yRowStride,
  int uvRowStride,
  int uvPixelStride,
) {
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
      int g = (yValue -
              0.337633 * (uValue - 128) -
              0.698001 * (vValue - 128))
          .round();
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

/// Entry point for the long-lived detection isolate. Owns its own
/// [YoloDetector]/[Interpreter] instance (interpreters cannot cross isolate
/// boundaries) and does conversion + inference + NMS entirely off the UI
/// thread.
void _detectionWorker(SendPort uiPort) {
  final workerPort = ReceivePort();
  uiPort.send(workerPort.sendPort);

  YoloDetector? detector;

  workerPort.listen((dynamic message) async {
    if (message is! Map) return;
    final cmd = message['cmd'];

    if (cmd == 'init') {
      try {
        detector = YoloDetector();
        await detector!
            .loadModelWithBenchmark(message['modelBytes'] as Uint8List);
        uiPort.send({
          'type': 'ready',
          'delegate': detector!.activeDelegate,
          'benchmarkMs': detector!.benchmarkMs,
          'benchmarkPerCallMs': detector!.benchmarkPerCallMs,
          'inputSize': detector!.inputSize,
          'inputShape': detector!.inputShape,
        });
      } catch (e) {
        uiPort.send({'type': 'fatal', 'message': e.toString()});
      }
      return;
    }

    if (cmd == 'frame') {
      final det = detector;
      final id = message['id'] as int;
      if (det == null || !det.isLoaded) {
        uiPort.send({'type': 'error', 'id': id, 'message': 'model not ready'});
        return;
      }
      try {
        det.confidenceThreshold =
            (message['conf'] as num?)?.toDouble() ?? det.confidenceThreshold;
        det.iouThreshold =
            (message['iou'] as num?)?.toDouble() ?? det.iouThreshold;

        final width = message['width'] as int;
        final height = message['height'] as int;

        // Stage 1a: YUV420 → RGB conversion
        final yuvSw = Stopwatch()..start();
        final rgb = convertYUV420ToRGB(
          message['y'] as Uint8List,
          message['u'] as Uint8List,
          message['v'] as Uint8List,
          width,
          height,
          message['yRowStride'] as int,
          message['uvRowStride'] as int,
          message['uvPixelStride'] as int,
        );
        yuvSw.stop();

        final image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rgb.buffer,
          order: img.ChannelOrder.rgb,
        );

        // Stages 1b–3: letterbox + inference + postprocessing
        final staged = det.runInferenceFromImage(image);

        uiPort.send({
          'type': 'result',
          'id': id,
          'detections': staged.detections
              .map((d) => <String, dynamic>{
                    'l': d.left,
                    't': d.top,
                    'r': d.right,
                    'b': d.bottom,
                    'c': d.confidence,
                    'cls': d.classId,
                  })
              .toList(),
          'rawCount': staged.rawCount,
          'yuvMs': yuvSw.elapsedMicroseconds / 1000.0,
          'letterboxMs': staged.letterboxMs,
          'inferMs': staged.inferMs,
          'postMs': staged.postMs,
        });
      } catch (e) {
        uiPort.send({'type': 'error', 'id': id, 'message': e.toString()});
      }
      return;
    }

    if (cmd == 'dispose') {
      detector?.dispose();
      workerPort.close();
    }
  });
}

/// UI-side wrapper around the background detection isolate.
class DetectionIsolate {
  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;

  final Map<int, Completer<WorkerResult>> _pending = {};
  Completer<Map<String, dynamic>>? _readyCompleter;
  Uint8List? _pendingModelBytes;
  int _nextId = 0;
  bool _disposed = false;

  /// Spawns the worker, loads the model inside it (with delegate benchmark),
  /// and completes with the ready payload
  /// (`{delegate, benchmarkMs, inputSize}`). Throws on fatal init errors.
  Future<Map<String, dynamic>> start(Uint8List modelBytes) async {
    _receivePort = ReceivePort();
    _readyCompleter = Completer<Map<String, dynamic>>();
    _pendingModelBytes = modelBytes;

    _subscription = _receivePort!.listen(_handleMessage);
    _isolate = await Isolate.spawn(_detectionWorker, _receivePort!.sendPort);

    return _readyCompleter!.future;
  }

  void _handleMessage(dynamic message) {
    if (message is SendPort) {
      if (_workerPort == null) {
        _workerPort = message;
        // Handshake complete — kick off model load + delegate benchmark.
        _workerPort!.send({'cmd': 'init', 'modelBytes': _pendingModelBytes});
        _pendingModelBytes = null;
      }
      return;
    }
    if (message is! Map) return;
    final type = message['type'];

    if (type == 'ready') {
      _readyCompleter?.complete(Map<String, dynamic>.from(message));
      return;
    }
    if (type == 'fatal') {
      final err = StateError(message['message']?.toString() ?? 'worker init failed');
      if (!(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter?.completeError(err);
      }
      return;
    }
    if (type == 'result' || type == 'error') {
      final id = message['id'] as int;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (type == 'error') {
        completer.complete(WorkerResult(
          id: id,
          detections: const [],
          rawCount: 0,
          yuvMs: 0,
          letterboxMs: 0,
          inferMs: 0,
          postMs: 0,
          isolateSendMs: 0,
          isolateReceiveMs: 0,
          error: message['message']?.toString(),
        ));
        return;
      }
      final raw = (message['detections'] as List).cast<Map>();
      completer.complete(WorkerResult(
          id: id,
          detections: raw
              .map((d) => Detection(
                    left: (d['l'] as num).toDouble(),
                    top: (d['t'] as num).toDouble(),
                    right: (d['r'] as num).toDouble(),
                    bottom: (d['b'] as num).toDouble(),
                    confidence: (d['c'] as num).toDouble(),
                    classId: (d['cls'] as num).toInt(),
                  ))
              .toList(),
          rawCount: (message['rawCount'] as num?)?.toInt() ?? 0,
          yuvMs: (message['yuvMs'] as num?)?.toDouble() ?? 0,
          letterboxMs: (message['letterboxMs'] as num?)?.toDouble() ?? 0,
          inferMs: (message['inferMs'] as num?)?.toDouble() ?? 0,
          postMs: (message['postMs'] as num?)?.toDouble() ?? 0,
          isolateSendMs: 0, // filled by caller
          isolateReceiveMs: 0, // filled by caller
        ));
    }
  }

  /// Dispatches one raw YUV420 frame to the worker. The returned future
  /// completes with the detection result.
  Future<WorkerResult> processFrame({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int width,
    required int height,
    required int yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
    required double confidence,
    required double iou,
  }) {
    final id = _nextId++;
    final completer = Completer<WorkerResult>();
    _pending[id] = completer;

    // Measure how long it takes to serialize and send data into the isolate.
    final sendSw = Stopwatch()..start();
    _workerPort!.send({
      'cmd': 'frame',
      'id': id,
      'y': y,
      'u': u,
      'v': v,
      'width': width,
      'height': height,
      'yRowStride': yRowStride,
      'uvRowStride': uvRowStride,
      'uvPixelStride': uvPixelStride,
      'conf': confidence,
      'iou': iou,
    });
    sendSw.stop();

    // Wrap the future to capture receive time.
    final receiveSw = Stopwatch()..start();
    return completer.future.then((result) {
      receiveSw.stop();
      // Return a new result with the isolate timing injected.
      return WorkerResult(
        id: result.id,
        detections: result.detections,
        rawCount: result.rawCount,
        yuvMs: result.yuvMs,
        letterboxMs: result.letterboxMs,
        inferMs: result.inferMs,
        postMs: result.postMs,
        isolateSendMs: sendSw.elapsedMicroseconds / 1000.0,
        isolateReceiveMs: receiveSw.elapsedMicroseconds / 1000.0,
        error: result.error,
      );
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _workerPort?.send({'cmd': 'dispose'});
    } catch (_) {}
    _isolate?.kill(priority: Isolate.immediate);
    _subscription?.cancel();
    _receivePort?.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disposed'));
    }
    _pending.clear();
  }
}
