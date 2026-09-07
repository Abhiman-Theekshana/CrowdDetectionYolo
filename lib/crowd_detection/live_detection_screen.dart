import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';
import 'yolo_detector.dart';

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {
  final YoloDetector _detector = YoloDetector();
  final PersonTracker _tracker = PersonTracker();
  late LineCrossingDetector _crossingDetector;

  String _selectedDoor = 'Front';
  List<Detection> _latestDetections = [];
  final bool _showOverlays = false;

  @override
  void initState() {
    super.initState();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _detector.loadModel();
  }

  void _onResult(List<YOLOResult> results) {
    final detections = results
        .map((r) => Detection(
              left: r.boundingBox.left,
              top: r.boundingBox.top,
              right: r.boundingBox.right,
              bottom: r.boundingBox.bottom,
              confidence: r.confidence,
              classId: r.classIndex,
            ))
        .where((d) => d.confidence > 0.4)
        .toList();

    _tracker.update(detections);
    _crossingDetector.processFrame();

    if (mounted) {
      setState(() {
        _latestDetections = detections;
      });
    }
  }

  void _resetCounters() {
    _tracker.reset();
    _crossingDetector.reset();
    setState(() {
      _latestDetections = [];
    });
  }

  @override
  void dispose() {
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
          YOLOView(
            modelPath: 'assets/models/best.tflite',
            task: YOLOTask.detect,
            confidenceThreshold: 0.4,
            iouThreshold: 0.5,
            useGpu: false,
            showOverlays: _showOverlays,
            onResult: _onResult,
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
