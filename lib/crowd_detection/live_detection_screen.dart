import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:share_plus/share_plus.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';
import 'yolo_detector.dart';
import 'camera_service.dart';
import 'detection_isolate.dart';
import 'session_logger.dart';

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

/// Normalized doorway region of interest (0-1). Only detections whose center
/// falls inside are tracked/counted. Tune these to the mounted phone's view
/// of the doorway; full frame = previous behavior.
const Rect doorwayRoi = Rect.fromLTWH(0.0, 0.0, 1.0, 1.0);

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {
  final CameraService _cameraService = CameraService();
  final DetectionIsolate _worker = DetectionIsolate();
  late PersonTracker _tracker;
  late LineCrossingDetector _crossingDetector;

  bool _isDetecting = false;
  bool _frameInFlight = false;
  bool _workerReady = false;
  String _selectedDoor = 'Front';
  List<Detection> _latestDetections = [];
  String? _errorMessage;

  // Session logging.
  final SessionLogger _logger = SessionLogger();
  int _totalFrames = 0;
  double _inferMsSum = 0;
  bool _sessionStarted = false;
  int _lastLoggedFrame = 0;
  static const int _logFrameInterval = 10;

  // Post-session state.
  File? _logFile;
  bool _sessionEnded = false;

  // HUD state.
  bool _showHud = false;
  bool _useUltraWide = false;
  double _confidence = 0.35;
  double _iou = 0.45;
  double _fps = 0;
  double _yuvMs = 0;
  double _letterboxMs = 0;
  double _inferMs = 0;
  double _postMs = 0;
  double _isolateSendMs = 0;
  double _isolateReceiveMs = 0;
  String _delegateName = '…';
  Map<String, double> _benchmarkMs = {};
  Map<String, List<double>> _benchmarkPerCallMs = {};
  final List<DateTime> _frameTimes = [];

  @override
  void initState() {
    super.initState();
    _tracker = PersonTracker();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _crossingDetector.onCrossing = (direction, personId, occupancy) {
      _logger.logCrossing(
        direction: direction,
        personId: personId,
        occupancy: occupancy,
      );
    };
    _initialize();
  }

  Future<void> _initialize() async {
    // Start the session log.
    await _logger.startSession(door: _selectedDoor);
    _sessionStarted = true;

    // Spawn the background worker and benchmark delegates inside it.
    try {
      final modelBytes =
          (await rootBundle.load('assets/models/best.tflite')).buffer.asUint8List();
      final ready = await _worker.start(modelBytes);
      _delegateName = ready['delegate']?.toString() ?? 'cpu';
      final bench = ready['benchmarkMs'];
      if (bench is Map) {
        _benchmarkMs = bench.map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        );
      }
      final benchPerCall = ready['benchmarkPerCallMs'];
      if (benchPerCall is Map) {
        _benchmarkPerCallMs = benchPerCall.map(
          (k, v) => MapEntry(
            k.toString(),
            (v as List).map((e) => (e as num).toDouble()).toList(),
          ),
        );
      }

      final inputShapeRaw = ready['inputShape'];
      final inputShape = inputShapeRaw is List
          ? inputShapeRaw.map((e) => (e as num).toInt()).toList()
          : <int>[];

      _logger.logModelLoad(
        activeDelegate: _delegateName,
        benchmarkMs: _benchmarkMs,
        inputShape: inputShape,
        inputSize: ready['inputSize'] as int? ?? 320,
      );
      debugPrint('Detection worker ready (delegate=$_delegateName, '
          'benchmarkMs=$_benchmarkMs)');
    } catch (e) {
      _logger.logError(e);
      if (mounted) {
        setState(() => _errorMessage = 'Failed to load model: $e');
      }
      return;
    }

    try {
      await _cameraService.initializeCameras();
      await _cameraService.startCamera(useUltraWide: _useUltraWide);
    } catch (e) {
      _logger.logError(e);
      if (mounted) {
        setState(() => _errorMessage = 'Failed to start camera: $e');
      }
      return;
    }

    if (mounted) {
      setState(() => _workerReady = true);
    }
    _startDetection();
  }

  void _startDetection() {
    _isDetecting = true;
    _cameraService.frameStream.listen((RawCameraFrame frame) {
      if (!_isDetecting || !_workerReady || _frameInFlight) return;
      _processFrame(frame);
    });
  }

  Future<void> _processFrame(RawCameraFrame frame) async {
    _frameInFlight = true;

    try {
      final result = await _worker.processFrame(
        y: frame.y,
        u: frame.u,
        v: frame.v,
        width: frame.width,
        height: frame.height,
        yRowStride: frame.yRowStride,
        uvRowStride: frame.uvRowStride,
        uvPixelStride: frame.uvPixelStride,
        confidence: _confidence,
        iou: _iou,
      );

      if (result.error != null) {
        _logger.log('FRAME ERROR — ${result.error}');
        return;
      }

      _tracker.update(result.detections, roi: doorwayRoi);
      _crossingDetector.processFrame();

      _latestDetections = result.detections;
      _yuvMs = result.yuvMs;
      _letterboxMs = result.letterboxMs;
      _inferMs = result.inferMs;
      _postMs = result.postMs;
      _isolateSendMs = result.isolateSendMs;
      _isolateReceiveMs = result.isolateReceiveMs;

      _totalFrames++;
      _inferMsSum += result.inferMs;

      // Throttled per-frame logging (every N frames).
      if (_totalFrames - _lastLoggedFrame >= _logFrameInterval) {
        final maxConf = result.detections.isEmpty
            ? 0.0
            : result.detections
                .map((d) => d.confidence)
                .reduce((a, b) => a > b ? a : b);
        _logger.logFrame(
          frameNumber: _totalFrames,
          yuvMs: result.yuvMs,
          letterboxMs: result.letterboxMs,
          inferMs: result.inferMs,
          postMs: result.postMs,
          isolateSendMs: result.isolateSendMs,
          isolateReceiveMs: result.isolateReceiveMs,
          rawCount: result.rawCount,
          filteredCount: result.detections.length,
          maxConfidence: maxConf,
        );
        _lastLoggedFrame = _totalFrames;
      }

      final now = DateTime.now();
      _frameTimes.add(now);
      _frameTimes.removeWhere(
        (t) => now.difference(t).inMilliseconds > 1000,
      );
      _fps = _frameTimes.length.toDouble();

      if (mounted) setState(() {});
    } catch (e, stack) {
      _logger.logError(e, stack);
      debugPrint('Frame processing error: $e');
    } finally {
      _frameInFlight = false;
    }
  }

  void _resetCounters() {
    _tracker.reset();
    _crossingDetector.reset();
    _latestDetections = [];
    setState(() {});
  }

  Future<void> _toggleUltraWide() async {
    final newValue = !_useUltraWide;
    setState(() {
      _useUltraWide = newValue;
      _isDetecting = false;
      _frameInFlight = false;
      _workerReady = false;
    });
    try {
      await _cameraService.restartCamera(useUltraWide: newValue);
      if (mounted) setState(() => _workerReady = true);
      _startDetection();
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Camera restart failed: $e');
      }
    }
  }

  Future<void> _endSession() async {
    if (!_sessionStarted) return;
    _isDetecting = false;
    _cameraService.stopCamera();
    final avgInfer = _totalFrames > 0 ? _inferMsSum / _totalFrames : 0.0;
    _logFile = await _logger.endSession(
      entries: _crossingDetector.entries,
      exits: _crossingDetector.exits,
      totalFrames: _totalFrames,
      avgInferMs: avgInfer,
    );
    _sessionEnded = true;
    if (mounted) setState(() {});
  }

  Future<void> _shareLogFile() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Crowd detection session log',
    );
  }

  @override
  void dispose() {
    _isDetecting = false;
    _cameraService.dispose();
    _worker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_errorMessage != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else if (_sessionEnded)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Session Complete',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$_totalFrames frames  ·  avg ${(_inferMsSum / (_totalFrames > 0 ? _totalFrames : 1)).toStringAsFixed(1)}ms/frame',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Tap "Share Log" to send the session log file,',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const Text(
                      'or "Back" to return to the home screen.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            )
          else if (_cameraService.isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cameraService.controller!.value.previewSize?.height ??
                      MediaQuery.of(context).size.width,
                  height: _cameraService.controller!.value.previewSize?.width ??
                      MediaQuery.of(context).size.height,
                  child: CameraPreview(_cameraService.controller!),
                ),
              ),
            )
          else
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text(
                    'Loading model (benchmarking delegates)…',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

          if (!_sessionEnded) ...[
            CustomPaint(
              size: Size.infinite,
              painter: _OverlayPainter(
                linePosition: _crossingDetector.linePosition,
                detections: _latestDetections,
              ),
            ),

            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              right: 16,
              child: _buildStatsPanel(),
            ),

            if (_showHud)
              Positioned(
                bottom:
                    MediaQuery.of(context).padding.bottom + 76,
                left: 16,
                right: 16,
                child: _buildHudPanel(),
              ),
          ] else
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              right: 16,
              child: _buildStatsPanel(),
            ),

          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
            child: _buildControlPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatBox('Entries', _crossingDetector.entries, Colors.green),
              _buildStatBox('Exits', _crossingDetector.exits, Colors.red),
              _buildStatBox(
                  'Occupancy', _crossingDetector.occupancy, Colors.blue),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Door: ',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              DropdownButton<String>(
                value: _selectedDoor,
                dropdownColor: Colors.grey[800],
                style: const TextStyle(color: Colors.white),
                underline: Container(),
                items: ['Front', 'Back'].map((String door) {
                  return DropdownMenuItem<String>(
                    value: door,
                    child: Text(door),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedDoor = newValue!;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatBox(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildHudPanel() {
    final totalMs = _yuvMs + _letterboxMs + _inferMs + _postMs +
        _isolateSendMs + _isolateReceiveMs;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'FPS ${_fps.toStringAsFixed(0)}  ·  $_delegateName'
                '${_useUltraWide ? "  ·  ${_cameraService.lensModeLabel}" : ""}',
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'TOTAL ${totalMs.toStringAsFixed(0)}ms',
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Staged timing breakdown
          Text(
            'yuv: ${_yuvMs.toStringAsFixed(1)}  '
            'letterbox: ${_letterboxMs.toStringAsFixed(1)}  '
            'infer: ${_inferMs.toStringAsFixed(1)}  '
            'post: ${_postMs.toStringAsFixed(1)}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'send: ${_isolateSendMs.toStringAsFixed(1)}  '
            'recv: ${_isolateReceiveMs.toStringAsFixed(1)}',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          if (_benchmarkMs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'benchmark avg: ${_benchmarkMs.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)}ms').join('  ·  ')}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          if (_benchmarkPerCallMs.isNotEmpty)
            ..._benchmarkPerCallMs.entries.map((e) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${e.key}: [${e.value.map((v) => v.toStringAsFixed(0)).join(', ')}]',
                    style: const TextStyle(
                      color: Colors.white30,
                      fontSize: 9,
                      fontFamily: 'monospace',
                    ),
                  ),
                )),
          _buildHudSlider(
            label: 'Conf ${_confidence.toStringAsFixed(2)}',
            value: _confidence,
            onChanged: (v) => setState(() => _confidence = v),
          ),
          _buildHudSlider(
            label: 'IoU ${_iou.toStringAsFixed(2)}',
            value: _iou,
            onChanged: (v) => setState(() => _iou = v),
          ),
          const Divider(color: Colors.white24, height: 12),
          _buildLensRow(),
        ],
      ),
    );
  }

  Widget _buildHudSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0.1,
            max: 0.9,
            divisions: 16,
            activeColor: Colors.cyanAccent,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildLensRow() {
    final lensLabel = _cameraService.lensModeLabel;
    return Row(
      children: [
        const Icon(Icons.wifi_outlined, color: Colors.white70, size: 16),
        const SizedBox(width: 6),
        const Text(
          'Ultra-wide',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
        const Spacer(),
        if (_useUltraWide)
          Text(
            lensLabel,
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        const SizedBox(width: 6),
        SizedBox(
          height: 24,
          child: Switch(
            value: _useUltraWide,
            onChanged: _workerReady ? (_) => _toggleUltraWide() : null,
            activeThumbColor: Colors.cyanAccent,
            trackColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return Colors.cyanAccent.withValues(alpha: 0.5);
              }
              return Colors.grey;
            }),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          onPressed: _sessionEnded ? null : _resetCounters,
          icon: const Icon(Icons.refresh),
          label: const Text('Reset'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        ElevatedButton.icon(
          onPressed: () => setState(() => _showHud = !_showHud),
          icon: Icon(_showHud ? Icons.speed : Icons.speed_outlined),
          label: const Text('HUD'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _showHud ? Colors.cyan[700] : Colors.grey[800],
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
        if (_sessionEnded && _logFile != null)
          ElevatedButton.icon(
            onPressed: _shareLogFile,
            icon: const Icon(Icons.share),
            label: const Text('Share Log'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          )
        else
          ElevatedButton.icon(
            onPressed: _endSession,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
        if (_sessionEnded)
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[700],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
      ],
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final double linePosition;
  final List<Detection> detections;

  _OverlayPainter({required this.linePosition, required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final lineY = size.height * linePosition;

    // Draw Virtual Threshold Line
    final linePaint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(0, lineY),
      Offset(size.width, lineY),
      linePaint,
    );

    // Label: OUTSIDE (OUT) - Top side of line
    final outTextPainter = TextPainter(
      text: const TextSpan(
        text: '▲ OUTSIDE (OUT)',
        style: TextStyle(
          color: Colors.redAccent,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    outTextPainter.layout();

    // Draw OUT background badge
    final outBgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(12, lineY - 28, outTextPainter.width + 16, 22),
      const Radius.circular(6),
    );
    final outBgPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(outBgRect, outBgPaint);
    outTextPainter.paint(canvas, Offset(20, lineY - 24));

    // Label: INSIDE (IN) - Bottom side of line
    final inTextPainter = TextPainter(
      text: const TextSpan(
        text: '▼ INSIDE (IN)',
        style: TextStyle(
          color: Colors.greenAccent,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    inTextPainter.layout();

    // Draw IN background badge
    final inBgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(12, lineY + 8, inTextPainter.width + 16, 22),
      const Radius.circular(6),
    );
    final inBgPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(inBgRect, inBgPaint);
    inTextPainter.paint(canvas, Offset(20, lineY + 12));

    // Label: Center Threshold Title
    final lineTitlePainter = TextPainter(
      text: const TextSpan(
        text: '━━ DOORWAY THRESHOLD ━━',
        style: TextStyle(
          color: Colors.yellow,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    lineTitlePainter.layout();
    lineTitlePainter.paint(
        canvas, Offset(size.width - lineTitlePainter.width - 16, lineY - 18));

    // Draw Bounding Boxes
    final boxPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;

    for (final det in detections) {
      final rect = Rect.fromLTRB(
        det.left * size.width,
        det.top * size.height,
        det.right * size.width,
        det.bottom * size.height,
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: 'Person ${(det.confidence * 100).toInt()}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.green,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(rect.left, rect.top - 14));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
