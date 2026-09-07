import 'package:flutter/material.dart';
import '../models/frame_analysis_result.dart';

class VideoResultsScreen extends StatelessWidget {
  final int entries;
  final int exits;
  final int totalFrames;
  final int totalDetections;
  final int framesSucceeded;
  final int framesFailed;
  final List<FrameAnalysisResult> frameResults;
  final String videoName;

  const VideoResultsScreen({
    super.key,
    required this.entries,
    required this.exits,
    required this.totalFrames,
    required this.totalDetections,
    required this.framesSucceeded,
    required this.framesFailed,
    required this.frameResults,
    required this.videoName,
  });

  @override
  Widget build(BuildContext context) {
    final net = entries - exits;
    final hasDetections = totalDetections > 0;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('Analysis Results'),
        backgroundColor: Colors.grey[850],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Diagnostic verdict
                  _buildDiagnosticVerdict(hasDetections),

                  const SizedBox(height: 24),

                  // Summary cards
                  _buildSummarySection(net),

                  const SizedBox(height: 24),

                  // Per-frame breakdown
                  _buildFrameBreakdown(),
                ],
              ),
            ),
          ),

          // Bottom button
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[850],
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to Video Selection'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticVerdict(bool hasDetections) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: hasDetections
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasDetections
              ? Colors.green.withValues(alpha: 0.5)
              : Colors.amber.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        children: [
          Icon(
            hasDetections ? Icons.check_circle : Icons.warning,
            color: hasDetections ? Colors.green : Colors.amber,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            hasDetections
                ? 'Model is detecting people correctly'
                : 'No detections found in any frame',
            style: TextStyle(
              color: hasDetections ? Colors.green : Colors.amber,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          if (!hasDetections) ...[
            const SizedBox(height: 12),
            const Text(
              'Model or video may have an issue. Check:\n'
              '• Is there a visible person in the video?\n'
              '• Was the model loaded successfully?\n'
              '• Try a different confidence threshold',
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummarySection(int net) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Summary',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildResultCard('Entered', entries, Colors.green, Icons.login),
            _buildResultCard('Left', exits, Colors.red, Icons.logout),
            _buildResultCard('Net', net, Colors.blue, Icons.people),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              _buildStatRow('Video', videoName),
              _buildStatRow('Total frames analyzed', '$totalFrames'),
              _buildStatRow('Total detections', '$totalDetections'),
              _buildStatRow('Frames succeeded', '$framesSucceeded'),
              _buildStatRow('Frames failed', '$framesFailed'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildFrameBreakdown() {
    if (frameResults.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Per-Frame Breakdown',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 300,
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: frameResults.length,
            itemBuilder: (context, index) {
              final result = frameResults[index];
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: result.hasError
                      ? Colors.red.withValues(alpha: 0.1)
                      : Colors.grey[750],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: result.hasError
                        ? Colors.red.withValues(alpha: 0.3)
                        : Colors.grey[600]!,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: result.hasError
                            ? Colors.red.withValues(alpha: 0.2)
                            : result.detectionCount > 0
                                ? Colors.green.withValues(alpha: 0.2)
                                : Colors.grey[700],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${result.frameNumber}',
                        style: TextStyle(
                          color: result.hasError
                              ? Colors.red
                              : result.detectionCount > 0
                                  ? Colors.green
                                  : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.hasError
                                ? 'Error: ${result.error}'
                                : '${result.detectionCount} detection(s)',
                            style: TextStyle(
                              color: result.hasError ? Colors.red : Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          if (result.detectionCount > 0)
                            Text(
                              'Highest confidence: ${result.highestConfidence.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(String label, int value, Color color, IconData icon) {
    return Container(
      width: 100,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            value.toString(),
            style: TextStyle(
              color: color,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
