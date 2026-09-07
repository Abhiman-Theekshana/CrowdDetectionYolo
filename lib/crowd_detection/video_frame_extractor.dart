import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

class VideoFrameExtractor {
  final VideoPlayerController controller;
  final GlobalKey repaintKey;

  VideoFrameExtractor({
    required this.controller,
    required this.repaintKey,
  });

  Future<Uint8List?> captureCurrentFrame() async {
    final boundary = repaintKey.currentContext?.findRenderObject()
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
