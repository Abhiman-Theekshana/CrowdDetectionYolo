import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';
import 'yolo_detector.dart';
import 'frame_preprocessor.dart';
import 'camera_service.dart';

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {
  final CameraService _cameraService = CameraService();
  final YoloDetector _detector = YoloDetector();
  late PersonTracker _tracker;
  late LineCrossingDetector _crossingDetector;

  bool _isDetecting = false;
  bool _isProcessingFrame = false;
  int _frameCount = 0;
  String _selectedDoor = 'Front';
  List<Detection> _latestDetections = [];

  @override
  void initState() {
    super.initState();
    _tracker = PersonTracker();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _initialize();
  }

  Future<void> _initialize() async {
    await _detector.loadModel();
    await _cameraService.initializeCameras();
    await _cameraService.startCamera();

    if (mounted) setState(() {});

    _startDetection();
  }

  void _startDetection() {
    _isDetecting = true;
    _cameraService.imageStream.listen((CameraFrame frame) {
      if (!_isDetecting || _isProcessingFrame) return;

      _frameCount++;
      if (_frameCount % 3 != 0) return;

      _processFrame(frame);
    });
  }

  Future<void> _processFrame(CameraFrame frame) async {
    _isProcessingFrame = true;

    try {
      final input = FramePreprocessor.preprocessRgb(
        frame.bytes,
        frame.width,
        frame.height,
      );
      final detections = _detector.runInference(input, 320, 320);

      _tracker.update(detections);
      _crossingDetector.processFrame();

      _latestDetections = detections;

      if (mounted) {
        setState(() {});
      }
    } catch (e, stack) {
      debugPrint('Frame processing error: $e\n$stack');
    } finally {
      _isProcessingFrame = false;
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
    _cameraService.dispose();
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraService.isInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: _cameraService.controller!.value.aspectRatio,
                child: CameraPreview(_cameraService.controller!),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
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
              _buildStatBox('Occupancy', _crossingDetector.occupancy, Colors.blue),
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
    final linePaint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final lineY = size.height * linePosition;
    canvas.drawLine(
      Offset(0, lineY),
      Offset(size.width, lineY),
      linePaint,
    );

    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'VIRTUAL LINE',
        style: TextStyle(
          color: Colors.yellow,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(10, lineY - 20));

    final boxPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.15)
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
          text: '${(det.confidence * 100).toInt()}%',
          style: const TextStyle(
            color: Colors.green,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(rect.left, rect.top - 12));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
