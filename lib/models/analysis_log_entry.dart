class AnalysisLogEntry {
  final DateTime timestamp;
  final String message;
  final bool isError;

  AnalysisLogEntry({
    required this.timestamp,
    required this.message,
    this.isError = false,
  });

  String get timeString {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
