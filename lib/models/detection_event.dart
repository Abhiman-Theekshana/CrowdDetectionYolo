class DetectionEvent {
  final String direction;
  final int personId;
  final DateTime timestamp;

  DetectionEvent({
    required this.direction,
    required this.personId,
    required this.timestamp,
  });

  @override
  String toString() =>
      'DetectionEvent(direction: $direction, personId: $personId, timestamp: $timestamp)';
}
