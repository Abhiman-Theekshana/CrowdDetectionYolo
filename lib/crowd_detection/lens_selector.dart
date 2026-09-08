import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Identifies the ultra-wide (0.6x) rear camera on multi-lens Android phones
/// by comparing native focal lengths via a platform channel.  On devices with
/// only one rear lens (or where the platform channel is unavailable) the
/// default back camera is returned instead.
class LensSelector {
  static const _channel = MethodChannel('com.buzing.camera/ultra_wide');

  /// Cached result — resolved once per app session.
  static CameraDescription? _ultraWide;
  static bool _resolved = false;

  /// Returns the ultra-wide rear camera, or `null` if the device has only one
  /// back lens / the platform channel is unavailable.  The result is cached
  /// for the lifetime of the app.
  static Future<CameraDescription?> detectUltraWide() async {
    if (_resolved) return _ultraWide;

    try {
      final cameras = await availableCameras();
      final backCameras = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();

      if (backCameras.length <= 1) {
        // Only one back lens — nothing to choose.
        _ultraWide = null;
        _resolved = true;
        return _ultraWide;
      }

      // Query native focal lengths keyed by camera ID.
      final raw = await _channel.invokeMethod<Map>('getFocalLengths');
      if (raw == null || raw.isEmpty) {
        _resolved = true;
        return _ultraWide;
      }

      // Map camera name (ID string) → focal length.
      final focalByCamId = <String, double>{};
      for (final entry in raw.entries) {
        final val = entry.value;
        if (val is List && val.isNotEmpty) {
          focalByCamId[entry.key] = (val.first as num).toDouble();
        } else if (val is num) {
          focalByCamId[entry.key] = val.toDouble();
        }
      }

      if (focalByCamId.isEmpty) {
        _resolved = true;
        return _ultraWide;
      }

      // Attach focal lengths to each back camera; the one with the shortest
      // focal length is the ultra-wide.
      double minFocal = double.infinity;
      CameraDescription? shortest;
      for (final cam in backCameras) {
        final focal = focalByCamId[cam.name];
        if (focal != null && focal < minFocal) {
          minFocal = focal;
          shortest = cam;
        }
      }

      // Only use it if it's meaningfully shorter than the other lenses
      // (tolerance avoids mis-selecting on single-lens devices that happen
      // to expose multiple CameraDescriptions with identical optics).
      if (shortest != null && backCameras.length > 1) {
        final sorted = focalByCamId.values.toList()..sort();
        if (sorted.length >= 2) {
          final ratio = sorted.last / sorted.first;
          if (ratio > 1.3) {
            _ultraWide = shortest;
          }
        }
      }

      _resolved = true;
      return _ultraWide;
    } on PlatformException catch (_) {
      _resolved = true;
      return _ultraWide;
    } catch (_) {
      _resolved = true;
      return _ultraWide;
    }
  }

  /// Resets the cached result so the next call to [detectUltraWide] re-probes.
  static void resetCache() {
    _ultraWide = null;
    _resolved = false;
  }
}
