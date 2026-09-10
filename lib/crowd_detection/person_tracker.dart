import 'dart:math' show sqrt;
import 'dart:ui' show Offset, Rect;
import '../models/tracked_person.dart';
import 'yolo_detector.dart';

class PersonTracker {
  /// Max Euclidean distance (normalized) between a detection and a track's
  /// predicted position to consider them a match.
  final double maxDistance;

  /// Frames a track survives without being seen before removal.
  final int gracePeriodFrames;

  int _nextId = 0;

  final List<TrackedPerson> trackedPersons = [];

  PersonTracker({
    this.maxDistance = 0.20,
    this.gracePeriodFrames = 8,
  });

  /// Updates tracks with the latest frame's detections using 2D matching
  /// with velocity-predicted positions and Hungarian-style greedy assignment.
  void update(List<Detection> detections, {Rect roi = const Rect.fromLTWH(0, 0, 1, 1)}) {
    final inRoi = detections
        .where((d) => roi.contains(Offset(d.centerX, d.centerY)))
        .toList();

    if (inRoi.isEmpty && trackedPersons.isEmpty) return;

    final nDet = inRoi.length;
    final nTrk = trackedPersons.length;

    // Build cost matrix: Euclidean distance from each detection to each track's
    // predicted position (current position + velocity).
    final cost = List.generate(nDet, (_) => List.filled(nTrk, double.infinity));

    for (int i = 0; i < nDet; i++) {
      for (int j = 0; j < nTrk; j++) {
        final predX = trackedPersons[j].predictedX;
        final predY = trackedPersons[j].predictedY;
        final dx = inRoi[i].centerX - predX;
        final dy = inRoi[i].centerY - predY;
        cost[i][j] = sqrt(dx * dx + dy * dy);
      }
    }

    // Greedy assignment (good enough for 1-5 people).
    final matchedDet = List<bool>.filled(nDet, false);
    final matchedTrk = List<bool>.filled(nTrk, false);

    for (int attempt = 0; attempt < nDet * nTrk; attempt++) {
      double bestCost = double.infinity;
      int bestI = -1, bestJ = -1;

      for (int i = 0; i < nDet; i++) {
        if (matchedDet[i]) continue;
        for (int j = 0; j < nTrk; j++) {
          if (matchedTrk[j]) continue;
          if (cost[i][j] < bestCost) {
            bestCost = cost[i][j];
            bestI = i;
            bestJ = j;
          }
        }
      }

      if (bestI < 0 || bestCost > maxDistance) break;

      matchedDet[bestI] = true;
      matchedTrk[bestJ] = true;

      trackedPersons[bestJ].updateFromDetection(
        inRoi[bestI].centerX,
        inRoi[bestI].centerY,
        inRoi[bestI].width,
        inRoi[bestI].height,
        inRoi[bestI].confidence,
      );
    }

    // Increment unseen counter for unmatched tracks.
    for (int j = 0; j < nTrk; j++) {
      if (!matchedTrk[j]) {
        trackedPersons[j].framesSinceLastSeen++;
        // Keep predicting position during occlusion.
        trackedPersons[j].centerX = trackedPersons[j].predictedX;
        trackedPersons[j].centerY = trackedPersons[j].predictedY;
      }
    }

    // Remove tracks that have been invisible too long.
    trackedPersons.removeWhere(
      (p) => p.framesSinceLastSeen > gracePeriodFrames,
    );

    // Create new tracks for unmatched detections.
    for (int i = 0; i < nDet; i++) {
      if (!matchedDet[i]) {
        trackedPersons.add(TrackedPerson(
          id: _nextId++,
          centerX: inRoi[i].centerX,
          centerY: inRoi[i].centerY,
          boxWidth: inRoi[i].width,
          boxHeight: inRoi[i].height,
          confidence: inRoi[i].confidence,
        ));
      }
    }
  }

  void reset() {
    trackedPersons.clear();
    _nextId = 0;
  }
}
