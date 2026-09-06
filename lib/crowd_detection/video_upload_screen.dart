import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'frame_preprocessor.dart';
import 'yolo_detector.dart';
import 'person_tracker.dart';
import 'line_crossing.dart';

class VideoUploadScreen extends StatefulWidget {
  const VideoUploadScreen({super.key});

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  final GlobalKey _videoKey = GlobalKey();
  final YoloDetector _detector = YoloDetector();
  final PersonTracker _tracker = PersonTracker();
  late LineCrossingDetector _crossingDetector;

  VideoPlayerController? _videoController;
  String? _selectedVideoPath;
  String? _selectedVideoName;
  bool _isProcessing = false;
  bool _videoLoaded = false;
  double _progress = 0.0;
  int _entries = 0;
  int _exits = 0;
  String _status = 'Select a video to analyze';
  Timer? _captureTimer;

  @override
  void initState() {
    super.initState();
    _crossingDetector = LineCrossingDetector(tracker: _tracker);
    _detector.loadModel();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _videoController?.dispose();
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Video Analysis'),
        backgroundColor: Colors.grey[850],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildVideoSelection(),
            const SizedBox(height: 16),
            if (_videoLoaded && !_isProcessing) _buildVideoPreview(),
            const SizedBox(height: 16),
            _buildProcessingStatus(),
            const SizedBox(height: 16),
            _buildResults(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSelection() {
    return Card(
      color: Colors.grey[800],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(Icons.video_library, size: 64, color: Colors.blue[400]),
            const SizedBox(height: 16),
            Text(
              _selectedVideoName ?? 'No video selected',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _selectVideo,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Select Video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
                if (_videoLoaded && !_isProcessing) ...[
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _processVideo,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Process'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPreview() {
    if (_videoController == null || !_videoController!.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.grey[800],
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: RepaintBoundary(
          key: _videoKey,
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingStatus() {
    if (!_isProcessing && _selectedVideoPath == null) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.grey[800],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (_isProcessing) ...[
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: Colors.grey[700],
                valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
              const SizedBox(height: 8),
              Text(
                _progress > 0 ? '${(_progress * 100).toInt()}% Complete' : 'Processing...',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 4),
              Text(
                _status,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ] else if (_selectedVideoPath != null && !_videoLoaded) ...[
              const CircularProgressIndicator(color: Colors.blue),
              const SizedBox(height: 8),
              const Text(
                'Loading video...',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_entries == 0 && _exits == 0) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.grey[800],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text(
              'Results',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildResultBox('Entries', _entries, Colors.green),
                _buildResultBox('Exits', _exits, Colors.red),
                _buildResultBox('Net', _entries - _exits, Colors.blue),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Events logged: ${_crossingDetector.events.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _resetAndSelectNew,
              icon: const Icon(Icons.refresh),
              label: const Text('Analyze Another Video'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultBox(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: TextStyle(color: color, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }

  Future<void> _selectVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.video);
      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;

      await _videoController?.dispose();
      setState(() {
        _videoLoaded = false;
        _selectedVideoPath = path;
        _selectedVideoName = result.files.single.name;
        _status = 'Loading video...';
      });

      _videoController = VideoPlayerController.file(File(path));
      await _videoController!.initialize();

      _videoController!.addListener(() {
        if (mounted) setState(() {});
      });

      setState(() {
        _videoLoaded = true;
        _status = 'Video loaded. Tap Process to analyze.';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  Future<Uint8List?> _captureFrame() async {
    final boundary = _videoKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
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

  Future<void> _processVideo() async {
    if (_videoController == null || !_videoController!.value.isInitialized) return;

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _entries = 0;
      _exits = 0;
      _status = 'Processing frames...';
    });

    _tracker.reset();
    _crossingDetector.reset();

    final duration = _videoController!.value.duration.inMilliseconds;
    const captureIntervalMs = 500;
    int framesCaptured = 0;

    _videoController!.seekTo(Duration.zero);
    await Future.delayed(const Duration(milliseconds: 300));
    _videoController!.play();

    final completer = Completer<void>();

    _captureTimer = Timer.periodic(
      const Duration(milliseconds: captureIntervalMs),
      (timer) async {
        final currentPos = _videoController!.value.position.inMilliseconds;

        if (currentPos >= duration || !_isProcessing) {
          timer.cancel();
          _captureTimer = null;
          await _videoController!.pause();
          if (!completer.isCompleted) completer.complete();
          return;
        }

        final frameBytes = await _captureFrame();
        if (frameBytes != null) {
          try {
            final input = FramePreprocessor.preprocessPng(frameBytes);
            final detections = _detector.runInference(input, 320, 320);
            _tracker.update(detections);
            _crossingDetector.processFrame();
          } catch (e) {
            // skip bad frame
          }
          framesCaptured++;
        }

        if (mounted) {
          setState(() {
            _progress = currentPos / duration;
            _entries = _crossingDetector.entries;
            _exits = _crossingDetector.exits;
            _status = 'Processing: $framesCaptured frames analyzed';
          });
        }
      },
    );

    await completer.future;

    setState(() {
      _isProcessing = false;
      _progress = 1.0;
      _entries = _crossingDetector.entries;
      _exits = _crossingDetector.exits;
      _status = 'Processing complete! $framesCaptured frames analyzed.';
    });
  }

  void _resetAndSelectNew() {
    _captureTimer?.cancel();
    _captureTimer = null;
    setState(() {
      _selectedVideoPath = null;
      _selectedVideoName = null;
      _videoLoaded = false;
      _isProcessing = false;
      _progress = 0.0;
      _entries = 0;
      _exits = 0;
      _status = 'Select a video to analyze';
    });
    _videoController?.dispose();
    _videoController = null;
  }
}
