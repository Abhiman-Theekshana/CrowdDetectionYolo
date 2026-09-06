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

  void update(List<Detection> detections) {
    final matchedDetections = List<bool>.filled(detections.length, false);
    final matchedTracks = List<bool>.filled(trackedPersons.length, false);

    for (int i = 0; i < detections.length; i++) {
      double bestDist = double.infinity;
      int bestIdx = -1;

      for (int j = 0; j < trackedPersons.length; j++) {
        if (matchedTracks[j]) continue;

        final dist = (detections[i].centerY - trackedPersons[j].lastCentroidY).abs();
        if (dist < bestDist && dist < maxDistance) {
          bestDist = dist;
          bestIdx = j;
        }
      }

      if (bestIdx >= 0) {
        trackedPersons[bestIdx].lastCentroidY = detections[i].centerY;
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

    for (int i = 0; i < detections.length; i++) {
      if (!matchedDetections[i]) {
        trackedPersons.add(TrackedPerson(
          id: _nextId++,
          lastCentroidY: detections[i].centerY,
        ));
      }
    }
  }

  void reset() {
    trackedPersons.clear();
    _nextId = 0;
  }
}
