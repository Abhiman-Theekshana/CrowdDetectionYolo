import 'dart:io';
import 'package:video_player/video_player.dart';

class VideoFrameExtractor {
  VideoPlayerController? _controller;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;
  VideoPlayerController? get controller => _controller;
  Duration get duration => _controller?.value.duration ?? Duration.zero;
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  Future<void> loadVideo(String filePath) async {
    _controller = VideoPlayerController.file(File(filePath));
    await _controller!.initialize();
    _controller!.setLooping(true);
    _isInitialized = true;
  }

  Future<void> seekTo(Duration position) async {
    await _controller?.seekTo(position);
  }

  Future<void> play() async {
    await _controller?.play();
  }

  Future<void> pause() async {
    await _controller?.pause();
  }

  void dispose() {
    _controller?.dispose();
    _isInitialized = false;
  }
}
