import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import '../models/analysis_log_entry.dart';
import '../models/frame_analysis_result.dart';
import 'yolo_detector.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';
import 'video_results_screen.dart';

class VideoAnalyzingScreen extends StatefulWidget {
  final String videoPath;
  final String videoName;

  const VideoAnalyzingScreen({
    super.key,
    required this.videoPath,
    required this.videoName,
  });

  @override
  State<VideoAnalyzingScreen> createState() => _VideoAnalyzingScreenState();
}

class _VideoAnalyzingScreenState extends State<VideoAnalyzingScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  final List<AnalysisLogEntry> _logEntries = [];
  final List<FrameAnalysisResult> _frameResults = [];
  final PersonTracker _tracker = PersonTracker();
  late LineCrossingDetector _crossingDetector;

  VideoPlayerController? _videoController;
  YOLO? _yolo;

  bool _isAnalyzing = false;
  bool _isComplete = false;
  bool _hasError = false;
  int _currentFrame = 0;
  int _totalFrames = 0;
  int _totalDetections = 0;
  int _framesSucceeded = 0;
  int _framesFailed = 0;
  String? _errorMessage;

  static const Duration _frameInterval = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _startAnalysis();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _yolo?.dispose();
    super.dispose();
  }

  void _addLog(String message, {bool isError = false}) {
    setState(() {
      _logEntries.add(AnalysisLogEntry(
        timestamp: DateTime.now(),
        message: message,
        isError: isError,
      ));
    });
  }

  Future<void> _startAnalysis() async {
    setState(() {
      _isAnalyzing = true;
      _hasError = false;
    });

    _addLog('Video selected: ${widget.videoName}');

    // Step 1: Initialize video controller
    try {
      _videoController = VideoPlayerController.file(File(widget.videoPath));
      await _videoController!.initialize();

      final duration = _videoController!.value.duration;
      _addLog('Duration: ${duration.inSeconds}s');
    } catch (e) {
      _addLog('ERROR at video loading: $e', isError: true);
      setState(() {
        _hasError = true;
        _errorMessage = 'Failed to load video: $e';
        _isAnalyzing = false;
      });
      return;
    }

    // Step 2: Load YOLO model
    _addLog('Loading YOLO model...');
    try {
      _yolo = YOLO(
        modelPath: 'assets/models/best.tflite',
        task: YOLOTask.detect,
        useGpu: false,
      );
      await _yolo!.loadModel();
      _addLog('Model loaded successfully');
    } catch (e) {
      _addLog('ERROR at model loading: $e', isError: true);
      setState(() {
        _hasError = true;
        _errorMessage = 'Model failed to load: $e';
        _isAnalyzing = false;
      });
      return;
    }

    // Step 3: Calculate frames to extract
    final duration = _videoController!.value.duration;
    _totalFrames = (duration.inMilliseconds / _frameInterval.inMilliseconds).ceil();
    _addLog('Extracting frames from video (interval: every ${_frameInterval.inMilliseconds}ms)...');
    _addLog('Total frames to analyze: $_totalFrames');

    // Step 4: Analyze each frame
    setState(() {
      _currentFrame = 0;
    });

    _videoController!.seekTo(Duration.zero);
    await Future.delayed(const Duration(milliseconds: 300));
    _videoController!.play();

    for (int i = 0; i < _totalFrames; i++) {
      if (!_isAnalyzing) break;

      setState(() {
        _currentFrame = i + 1;
      });

      _addLog('Analyzing frame ${i + 1}/$_totalFrames...');

      try {
        // Seek to the frame position
        final position = Duration(milliseconds: i * _frameInterval.inMilliseconds);
        await _videoController!.seekTo(position);
        await Future.delayed(const Duration(milliseconds: 100));

        // Capture frame
        final frameBytes = await _captureFrame();
        if (frameBytes == null) {
          _frameResults.add(FrameAnalysisResult(
            frameNumber: i + 1,
            detections: [],
            error: 'Failed to capture frame',
          ));
          _framesFailed++;
          _addLog('Frame ${i + 1}: Failed to capture frame', isError: true);
          continue;
        }

        // Run inference
        final results = await _yolo!.predict(frameBytes);
        final detectionsRaw = results['detections'] as List<dynamic>? ?? [];

        final detections = detectionsRaw
            .map((d) => Detection(
                  left: (d['boundingBox']?['left'] as num?)?.toDouble() ?? 0,
                  top: (d['boundingBox']?['top'] as num?)?.toDouble() ?? 0,
                  right: (d['boundingBox']?['right'] as num?)?.toDouble() ?? 0,
                  bottom: (d['boundingBox']?['bottom'] as num?)?.toDouble() ?? 0,
                  confidence: (d['confidence'] as num?)?.toDouble() ?? 0,
                  classId: (d['classIndex'] as num?)?.toInt() ?? 0,
                ))
            .where((d) => d.confidence > 0.4)
            .toList();

        _frameResults.add(FrameAnalysisResult(
          frameNumber: i + 1,
          detections: detections,
        ));
        _framesSucceeded++;
        _totalDetections += detections.length;

        // Update tracker
        _tracker.update(detections);
        _crossingDetector.processFrame();

        // Log detections
        if (detections.isNotEmpty) {
          final confidences = detections.map((d) => d.confidence.toStringAsFixed(2)).toList();
          _addLog('Frame ${i + 1}: ${detections.length} detection(s) (confidences: $confidences)');
        } else {
          _addLog('Frame ${i + 1}: 0 detections');
        }
      } catch (e) {
        _frameResults.add(FrameAnalysisResult(
          frameNumber: i + 1,
          detections: [],
          error: e.toString(),
        ));
        _framesFailed++;
        _addLog('Frame ${i + 1}: ERROR - $e', isError: true);
      }

      // Update UI
      if (mounted) setState(() {});
    }

    // Step 5: Analysis complete
    _addLog('Analysis complete: $_totalFrames processed, $_totalDetections total detections');
    _addLog('Frames succeeded: $_framesSucceeded, Frames failed: $_framesFailed');

    setState(() {
      _isAnalyzing = false;
      _isComplete = true;
    });

    _videoController?.pause();
  }

  Future<Uint8List?> _captureFrame() async {
    final boundary = _repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (e) {
      return null;
    }
  }

  void _cancelAnalysis() {
    setState(() {
      _isAnalyzing = false;
    });
    _videoController?.pause();
  }

  void _viewResults() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => VideoResultsScreen(
          entries: _crossingDetector.entries,
          exits: _crossingDetector.exits,
          totalFrames: _totalFrames,
          totalDetections: _totalDetections,
          framesSucceeded: _framesSucceeded,
          framesFailed: _framesFailed,
          frameResults: _frameResults,
          videoName: widget.videoName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Analyzing Video'),
        backgroundColor: Colors.grey[850],
        actions: [
          if (_isAnalyzing)
            TextButton(
              onPressed: _cancelAnalysis,
              child: const Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Video preview
          if (_videoController != null && _videoController!.value.isInitialized)
            Container(
              height: 200,
              color: Colors.black,
              child: Center(
                child: RepaintBoundary(
                  key: _repaintKey,
                  child: AspectRatio(
                    aspectRatio: _videoController!.value.aspectRatio,
                    child: VideoPlayer(_videoController!),
                  ),
                ),
              ),
            ),

          // Progress section
          if (_isAnalyzing)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.grey[850],
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _totalFrames > 0 ? _currentFrame / _totalFrames : 0,
                    backgroundColor: Colors.grey[700],
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Frame $_currentFrame of $_totalFrames',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),

          // Error banner
          if (_hasError && _errorMessage != null)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.red.withValues(alpha: 0.2),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),

          // Completion summary
          if (_isComplete)
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.grey[800],
              child: Column(
                children: [
                  const Text(
                    'Analysis Complete',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Frames: $_framesSucceeded succeeded, $_framesFailed failed',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Text(
                    'Total detections: $_totalDetections',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _viewResults,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    ),
                    child: const Text('View Full Results'),
                  ),
                ],
              ),
            ),

          // Log panel
          Expanded(
            child: Container(
              color: Colors.black,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _logEntries.length,
                itemBuilder: (context, index) {
                  final entry = _logEntries[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: entry.isError ? Colors.red : Colors.green,
                        ),
                        children: [
                          TextSpan(
                            text: '[${entry.timeString}] ',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          TextSpan(text: entry.message),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
