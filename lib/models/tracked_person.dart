class TrackedPerson {
  final int id;

  // EMA-smoothed centroid (normalized 0-1).
  double centerX;
  double centerY;

  // EMA-smoothed bounding box (normalized 0-1).
  double boxWidth;
  double boxHeight;

  // Raw centroid from last detection (for matching).
  double rawCenterX;
  double rawCenterY;

  // Velocity estimate (normalized/frame) for motion prediction.
  double velX;
  double velY;

  double confidence;
  int framesSinceLastSeen;
  int totalFramesTracked;

  // Hysteresis state for line crossing.
  String? lastSide;
  String? candidateSide;
  int candidateFrames;

  static const double _emaAlpha = 0.5;

  TrackedPerson({
    required this.id,
    required double centerX,
    required double centerY,
    required double boxWidth,
    required double boxHeight,
    this.confidence = 0.0,
    this.lastSide,
    this.framesSinceLastSeen = 0,
    this.candidateSide,
    this.candidateFrames = 0,
  })  : centerX = centerX,
        centerY = centerY,
        boxWidth = boxWidth,
        boxHeight = boxHeight,
        rawCenterX = centerX,
        rawCenterY = centerY,
        velX = 0,
        velY = 0,
        totalFramesTracked = 1;

  /// Predict next position using velocity.
  double get predictedX => centerX + velX;
  double get predictedY => centerY + velY;

  /// Update smoothed position from a new detection.
  void updateFromDetection(double detCX, double detCY, double detW, double detH, double conf) {
    final newX = detCX;
    final newY = detCY;

    // Update velocity before smoothing.
    velX = newX - centerX;
    velY = newY - centerY;

    // EMA smooth.
    centerX = centerX + _emaAlpha * (newX - centerX);
    centerY = centerY + _emaAlpha * (newY - centerY);
    boxWidth = boxWidth + _emaAlpha * (detW - boxWidth);
    boxHeight = boxHeight + _emaAlpha * (detH - boxHeight);

    rawCenterX = newX;
    rawCenterY = newY;
    confidence = conf;
    framesSinceLastSeen = 0;
    totalFramesTracked++;
  }
}
