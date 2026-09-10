import '../models/detection_event.dart';
import 'person_tracker.dart';

class LineCrossingDetector {
  final PersonTracker tracker;
  final double linePosition;

  /// A side change is only counted after the person is observed on the new
  /// side for this many consecutive frames. Prevents detection jitter near
  /// the line from producing false entries/exits.
  final int requiredConsecutiveFrames;

  /// Called every time a crossing is confirmed. Useful for logging.
  void Function(String direction, int personId, int occupancy)? onCrossing;

  int entries = 0;
  int exits = 0;
  final List<DetectionEvent> events = [];

  LineCrossingDetector({
    required this.tracker,
    this.linePosition = 0.6,
    this.requiredConsecutiveFrames = 3,
  });

  int get occupancy => entries - exits;

  void processFrame() {
    for (final person in tracker.trackedPersons) {
      final currentSide = person.centerY < linePosition ? 'outside' : 'inside';

      if (person.lastSide == null) {
        // First observation establishes the confirmed side immediately.
        person.lastSide = currentSide;
        person.candidateSide = null;
        person.candidateFrames = 0;
        continue;
      }

      if (currentSide == person.lastSide) {
        // Still on the confirmed side — drop any pending candidate.
        person.candidateSide = null;
        person.candidateFrames = 0;
        continue;
      }

      // Person is on a different side than the confirmed one: accumulate
      // evidence before counting a crossing.
      if (person.candidateSide == currentSide) {
        person.candidateFrames++;
      } else {
        person.candidateSide = currentSide;
        person.candidateFrames = 1;
      }

      if (person.candidateFrames >= requiredConsecutiveFrames) {
        if (person.lastSide == 'outside' && currentSide == 'inside') {
          entries++;
          events.add(DetectionEvent(
            direction: 'entry',
            personId: person.id,
            timestamp: DateTime.now(),
          ));
          onCrossing?.call('entry', person.id, occupancy);
        } else if (person.lastSide == 'inside' && currentSide == 'outside') {
          exits++;
          events.add(DetectionEvent(
            direction: 'exit',
            personId: person.id,
            timestamp: DateTime.now(),
          ));
          onCrossing?.call('exit', person.id, occupancy);
        }
        person.lastSide = currentSide;
        person.candidateSide = null;
        person.candidateFrames = 0;
      }
    }
  }

  void reset() {
    entries = 0;
    exits = 0;
    events.clear();
  }
}
