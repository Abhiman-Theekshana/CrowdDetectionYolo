import '../models/detection_event.dart';
import 'person_tracker.dart';

class LineCrossingDetector {
  final PersonTracker tracker;
  final double linePosition;
  int entries = 0;
  int exits = 0;
  final List<DetectionEvent> events = [];

  LineCrossingDetector({
    required this.tracker,
    this.linePosition = 0.6,
  });

  int get occupancy => entries - exits;

  void processFrame() {
    for (final person in tracker.trackedPersons) {
      final currentSide = person.lastCentroidY < linePosition ? 'outside' : 'inside';

      if (person.lastSide != null && person.lastSide != currentSide) {
        if (person.lastSide == 'outside' && currentSide == 'inside') {
          entries++;
          events.add(DetectionEvent(
            direction: 'entry',
            personId: person.id,
            timestamp: DateTime.now(),
          ));
        } else if (person.lastSide == 'inside' && currentSide == 'outside') {
          exits++;
          events.add(DetectionEvent(
            direction: 'exit',
            personId: person.id,
            timestamp: DateTime.now(),
          ));
        }
      }

      person.lastSide = currentSide;
    }
  }

  void reset() {
    entries = 0;
    exits = 0;
    events.clear();
  }
}
