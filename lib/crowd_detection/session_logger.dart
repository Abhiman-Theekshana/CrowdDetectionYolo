import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

class SessionLogger {
  IOSink? _sink;
  File? _logFile;
  bool _sessionActive = false;

  bool get isActive => _sessionActive;
  File? get currentLogFile => _logFile;

  Future<void> startSession({required String door}) async {
    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    _logFile = File('${dir.path}/crowd_session_$timestamp.txt');
    _sink = _logFile!.openWrite(mode: FileMode.write);
    _sessionActive = true;
    log('SESSION START — door: $door');
  }

  void log(String message) {
    final ts = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final line = '[$ts] $message';
    try {
      _sink?.writeln(line);
    } catch (_) {
      // Never let a write failure crash the detection session.
    }
  }

  void logModelLoad({
    required String activeDelegate,
    required Map<String, double> benchmarkMs,
    required List<int> inputShape,
    required int inputSize,
  }) {
    log('MODEL LOAD — delegate: $activeDelegate, inputSize: $inputSize, '
        'inputShape: $inputShape');
    if (benchmarkMs.isNotEmpty) {
      final entries = benchmarkMs.entries
          .map((e) => '${e.key}=${e.value.toStringAsFixed(1)}ms')
          .join(', ');
      log('BENCHMARK — $entries');
    }
  }

  void logFrame({
    required int frameNumber,
    required double yuvMs,
    required double letterboxMs,
    required double inferMs,
    required double postMs,
    required double isolateSendMs,
    required double isolateReceiveMs,
    required int rawCount,
    required int filteredCount,
    required double maxConfidence,
  }) {
    final total = yuvMs + letterboxMs + inferMs + postMs +
        isolateSendMs + isolateReceiveMs;
    log('FRAME #$frameNumber — '
        'yuv: ${yuvMs.toStringAsFixed(1)}ms, '
        'letterbox: ${letterboxMs.toStringAsFixed(1)}ms, '
        'infer: ${inferMs.toStringAsFixed(1)}ms, '
        'post: ${postMs.toStringAsFixed(1)}ms, '
        'send: ${isolateSendMs.toStringAsFixed(1)}ms, '
        'recv: ${isolateReceiveMs.toStringAsFixed(1)}ms, '
        'TOTAL: ${total.toStringAsFixed(1)}ms | '
        'raw: $rawCount, filtered: $filteredCount, '
        'maxConf: ${maxConfidence.toStringAsFixed(3)}');
  }

  void logCrossing({
    required String direction,
    required int personId,
    required int occupancy,
  }) {
    log('CROSSING — $direction, personId: $personId, occupancy: $occupancy');
  }

  void logError(Object error, [StackTrace? stack]) {
    log('ERROR — $error');
    if (stack != null) {
      final short = stack.toString().split('\n').take(8).join('\n');
      log('STACK — $short');
    }
  }

  Future<File?> endSession({
    required int entries,
    required int exits,
    required int totalFrames,
    required double avgInferMs,
  }) async {
    log('SESSION END — entries: $entries, exits: $exits, '
        'occupancy: ${entries - exits}, frames: $totalFrames, '
        'avgInfer: ${avgInferMs.toStringAsFixed(1)}ms');
    _sessionActive = false;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    return _logFile;
  }
}
