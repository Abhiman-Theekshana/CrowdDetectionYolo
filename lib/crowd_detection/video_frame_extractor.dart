import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';

class VideoFrameExtractor {
  final String videoPath;

  VideoFrameExtractor({required this.videoPath});

  Future<Uint8List?> extractFrameAt(Duration position) async {
    try {
      final thumbnail = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.PNG,
        timeMs: position.inMilliseconds,
        quality: 100,
      );
      return thumbnail;
    } catch (e) {
      return null;
    }
  }

  Future<List<FrameTimestamp>> calculateFrameTimestamps({
    required Duration duration,
    required Duration interval,
  }) async {
    final timestamps = <FrameTimestamp>[];
    int frameNumber = 1;
    Duration position = Duration.zero;

    while (position < duration) {
      timestamps.add(FrameTimestamp(
        frameNumber: frameNumber,
        position: position,
      ));
      frameNumber++;
      position += interval;
    }

    return timestamps;
  }
}

class FrameTimestamp {
  final int frameNumber;
  final Duration position;

  FrameTimestamp({
    required this.frameNumber,
    required this.position,
  });
}
