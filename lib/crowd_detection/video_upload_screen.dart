import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'video_analyzing_screen.dart';

class VideoUploadScreen extends StatefulWidget {
  const VideoUploadScreen({super.key});

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  VideoPlayerController? _videoController;
  String? _selectedVideoPath;
  String? _selectedVideoName;
  bool _isLoading = false;

  @override
  void dispose() {
    _videoController?.dispose();
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.grey[800],
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Icon(Icons.video_library, size: 80, color: Colors.blue[400]),
                    const SizedBox(height: 24),
                    Text(
                      _selectedVideoName ?? 'No video selected',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 24),
                    if (_isLoading)
                      const CircularProgressIndicator(color: Colors.blue)
                    else ...[
                      ElevatedButton.icon(
                        onPressed: _selectVideo,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Select Video'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                          textStyle: const TextStyle(fontSize: 16),
                        ),
                      ),
                      if (_selectedVideoPath != null) ...[
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _startAnalysis,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start Analysis'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32,
                              vertical: 16,
                            ),
                            textStyle: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                children: [
                  Icon(Icons.info_outline, color: Colors.white54, size: 24),
                  SizedBox(height: 8),
                  Text(
                    'Select a video to analyze for people detection.\n'
                    'The app will extract frames and run YOLO detection on each frame.',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectVideo() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.video);
      if (result == null || result.files.single.path == null) return;

      final path = result.files.single.path!;

      setState(() {
        _isLoading = true;
      });

      await _videoController?.dispose();
      _videoController = VideoPlayerController.file(File(path));
      await _videoController!.initialize();

      setState(() {
        _selectedVideoPath = path;
        _selectedVideoName = result.files.single.name;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading video: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _startAnalysis() {
    if (_selectedVideoPath == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoAnalyzingScreen(
          videoPath: _selectedVideoPath!,
          videoName: _selectedVideoName ?? 'Unknown',
        ),
      ),
    ).then((_) {
      // Reset state when returning from analysis
      setState(() {
        _selectedVideoPath = null;
        _selectedVideoName = null;
        _videoController?.dispose();
        _videoController = null;
      });
    });
  }
}
