class TrackedPerson {
  final int id;
  double lastCentroidY;
  String? lastSide;
  int framesSinceLastSeen;

  // Hysteresis state: a side change is only confirmed after the person is
  // seen on the new side for [LineCrossingDetector.requiredConsecutiveFrames]
  // consecutive frames. Until then the candidate is tracked here and
  // [lastSide] keeps the last confirmed side.
  String? candidateSide;
  int candidateFrames;

  TrackedPerson({
    required this.id,
    required this.lastCentroidY,
    this.lastSide,
    this.framesSinceLastSeen = 0,
    this.candidateSide,
    this.candidateFrames = 0,
  });
}
