import 'dart:ui' show Offset, Rect;
import '../models/tracked_person.dart';
import 'yolo_detector.dart';

class PersonTracker {
  final double maxDistance;
  final int gracePeriodFrames;
  int _nextId = 0;

  final List<TrackedPerson> trackedPersons = [];

  PersonTracker({
    this.maxDistance = 0.15,
    this.gracePeriodFrames = 3,
  });

  /// Updates tracks with the latest frame's detections.
  ///
  /// [roi] is a normalized (0-1) region of interest around the doorway.
  /// Detections whose center falls outside it are ignored for tracking and
  /// counting (e.g. seated passengers, people outside a window). Defaults to
  /// the full frame, which preserves the previous behavior.
  void update(List<Detection> detections, {Rect roi = const Rect.fromLTWH(0, 0, 1, 1)}) {
    final inRoi = detections
        .where((d) => roi.contains(Offset(d.centerX, d.centerY)))
        .toList();

    final matchedDetections = List<bool>.filled(inRoi.length, false);
    final matchedTracks = List<bool>.filled(trackedPersons.length, false);

    for (int i = 0; i < inRoi.length; i++) {
      double bestDist = double.infinity;
      int bestIdx = -1;

      for (int j = 0; j < trackedPersons.length; j++) {
        if (matchedTracks[j]) continue;

        final dist = (inRoi[i].centerY - trackedPersons[j].lastCentroidY).abs();
        if (dist < bestDist && dist < maxDistance) {
          bestDist = dist;
          bestIdx = j;
        }
      }

      if (bestIdx >= 0) {
        trackedPersons[bestIdx].lastCentroidY = inRoi[i].centerY;
        trackedPersons[bestIdx].framesSinceLastSeen = 0;
        matchedDetections[i] = true;
        matchedTracks[bestIdx] = true;
      }
    }

    for (int j = 0; j < trackedPersons.length; j++) {
      if (!matchedTracks[j]) {
        trackedPersons[j].framesSinceLastSeen++;
      }
    }

    trackedPersons.removeWhere(
      (p) => p.framesSinceLastSeen > gracePeriodFrames,
    );

    for (int i = 0; i < inRoi.length; i++) {
      if (!matchedDetections[i]) {
        trackedPersons.add(TrackedPerson(
          id: _nextId++,
          lastCentroidY: inRoi[i].centerY,
        ));
      }
    }
  }

  void reset() {
    trackedPersons.clear();
    _nextId = 0;
  }
}
