import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';
import 'yolo_detector.dart';
import 'camera_service.dart';
import 'detection_isolate.dart';

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

  // HUD state.
  bool _showHud = false;
  double _confidence = 0.35;
  double _iou = 0.45;
  double _fps = 0;
  double _preMs = 0;
  double _inferMs = 0;
  double _postMs = 0;
  String _delegateName = '…';
  Map<String, double> _benchmarkMs = {};
  final List<DateTime> _frameTimes = [];

  @override
  void initState() {
    super.initState();
    _tracker = PersonTracker();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _initialize();
  }

  Future<void> _initialize() async {
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
      debugPrint('Detection worker ready (delegate=$_delegateName, '
          'benchmarkMs=$_benchmarkMs)');
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to load model: $e');
      }
      return;
    }

    try {
      await _cameraService.initializeCameras();
      await _cameraService.startCamera();
    } catch (e) {
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
        debugPrint('Worker frame error: ${result.error}');
        return;
      }

      _tracker.update(result.detections, roi: doorwayRoi);
      _crossingDetector.processFrame();

      _latestDetections = result.detections;
      _preMs = result.preMs;
      _inferMs = result.inferMs;
      _postMs = result.postMs;

      final now = DateTime.now();
      _frameTimes.add(now);
      _frameTimes.removeWhere(
        (t) => now.difference(t).inMilliseconds > 1000,
      );
      _fps = _frameTimes.length.toDouble();

      if (mounted) setState(() {});
    } catch (e) {
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
                'FPS ${_fps.toStringAsFixed(0)}  ·  $_delegateName',
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                '${_preMs.toStringAsFixed(1)}ms pre · '
                '${_inferMs.toStringAsFixed(1)}ms inference · '
                '${_postMs.toStringAsFixed(1)}ms post',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (_benchmarkMs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'benchmark: ${_benchmarkMs.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(1)}ms').join('  ·  ')}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
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

  Widget _buildControlPanel() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          onPressed: _resetCounters,
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
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(context);
          },
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
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
