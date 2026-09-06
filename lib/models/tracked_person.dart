class TrackedPerson {
  final int id;
  double lastCentroidY;
  String? lastSide;
  int framesSinceLastSeen;

  TrackedPerson({
    required this.id,
    required this.lastCentroidY,
    this.lastSide,
    this.framesSinceLastSeen = 0,
  });
}
