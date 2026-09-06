# Crowd Detection App — Diagnosed Issues
### Project: Buzing.lk — Bus Doorway Crowd Counter (Flutter)
### Status: App runs, but detection pipeline never completes — no counts, no boxes, no output

---

## Summary

The app boots, the camera preview shows, and the virtual line overlay draws — so it *looks* alive. But the actual detection → tracking → counting pipeline never successfully completes a single frame. There are two independent, blocking bugs in Feature 1 (Live Camera Detection), and Feature 2 (Video Upload Detection) was never actually wired up past the file picker. Fixing only one of the two Feature 1 bugs will not make the app work — both must be fixed.

---

## Issue 1 — Camera frames are never decoded (root cause of "does nothing")

**File:** `lib/crowd_detection/camera_service.dart`
**Severity:** Critical / blocking

```dart
Uint8List? _convertCameraImage(CameraImage image) {
  final planes = image.planes;
  if (planes.isEmpty) return null;
  return Uint8List.fromList(planes[0].bytes);   // ❌ treats raw pixel data as a JPEG
}
```

`CameraController.startImageStream()` delivers **raw YUV420 planar pixel data on Android** (or BGRA8888 on iOS) — not an encoded image file. The code takes the first plane's raw bytes and passes them downstream as if they were JPEG-encoded bytes.

**Where it breaks:** `lib/crowd_detection/frame_preprocessor.dart`
```dart
final image = img.decodeImage(jpegBytes);
if (image == null) throw Exception('Failed to decode image');
```
`decodeImage()` expects an actual encoded image (JPEG/PNG/etc. with a valid header). Raw YUV bytes have no such header, so this always returns `null` and always throws.

**Why you never see an error:** In `lib/crowd_detection/live_detection_screen.dart`, this exception is caught and only printed to the debug console:
```dart
} catch (e) {
  debugPrint('Error processing frame: $e');   // invisible in the running app
}
```
Every single frame silently fails here, forever. Nothing in the UI reflects it.

**Fix direction:** Convert the YUV420/BGRA8888 `CameraImage` planes into an RGB image directly (standard YUV→RGB conversion using the Y/U/V planes and their strides), rather than passing raw plane bytes to a JPEG decoder. This conversion should happen where the camera frame is first captured, or in the preprocessor with a dedicated `preprocessCameraImage(CameraImage image)` method — not through `img.decodeImage()`.

---

## Issue 2 — Model output is discarded even when inference runs

**File:** `lib/crowd_detection/yolo_detector.dart`
**Severity:** Critical / blocking (independent of Issue 1)

```dart
final outputBuffer = Float32List.fromList(
  output.expand((e) => e.expand((e2) => e2)).toList(),
).buffer;

_interpreter!.run(inputBuffer, outputBuffer);   // writes results into outputBuffer

final outputData = output;                       // ❌ still the original, all-zero list
return _parseOutput(outputData, inputWidth, inputHeight);
```

`outputBuffer` is a **new, disconnected chunk of memory** built by flattening the original all-zero `output` list. `Interpreter.run()` writes the model's results into `outputBuffer`, but the code then parses `output` — the original nested list — which was never modified and still contains all zeros.

**Consequence:** `confidence` is always `0` for every candidate box, which always fails the `if (confidence > 0.4)` check in `_parseOutput`. Result: **zero detections, always** — even with a perfectly valid, correctly decoded input frame. This means fixing Issue 1 alone would not make detection work; this bug independently guarantees no output.

**Secondary problem in the same file:** the output tensor shape is hardcoded:
```dart
final outputShape = [1, 5, 3136];
```
For a YOLOv8n model exported at 320×320 input, the expected anchor count is typically **2100** (40×40 + 20×20 + 10×10 grid cells = 1600 + 400 + 100), not 3136. This number should be read from the model's actual output tensor at runtime (`interpreter.getOutputTensor(0).shape`) rather than hardcoded/guessed — a mismatch here will cause incorrect parsing or a runtime crash.

**Fix direction:** Use `Interpreter.run(input, output)` with properly shaped nested `List` objects matching the interpreter's real input/output tensor shapes (read via `getInputTensor(0).shape` / `getOutputTensor(0).shape` at load time), letting `tflite_flutter` handle the marshalling — rather than manually constructing and swapping `ByteBuffer`s.

---

## Issue 3 — Video Analysis (Feature 2) is a UI shell only — not implemented

**Files:** `lib/crowd_detection/video_upload_screen.dart`, `lib/crowd_detection/video_frame_extractor.dart`
**Severity:** Feature incomplete (not a bug — never built past the picker)

- `video_upload_screen.dart` lets the user pick a video file and shows a "Video selected. Ready to process." status — but there is no button or code path anywhere that calls the detection pipeline on the video.
- `video_frame_extractor.dart`'s core method is a stub:
  ```dart
  Future<Uint8List?> extractFrameAt(Duration position) async {
    if (_controller == null) return null;
    await _controller!.seekTo(position);
    await Future.delayed(const Duration(milliseconds: 100));
    return null;   // ❌ never actually extracts a frame
  }
  ```
  `video_player` (the package in use here) can play video and seek to a timestamp, but it does **not** expose raw frame pixel data — so this approach can't work as written regardless of bug fixing.

**Fix direction:** This lines up with the original spec's own note that video frame extraction was "TBD — evaluate options during implementation." A frame-extraction-capable plugin (e.g. `video_thumbnail`, which can pull a JPEG frame at a given timestamp) or an FFmpeg-based approach is needed, then wired into `video_upload_screen.dart` with an actual "Start Processing" action that loops over sampled timestamps, extracts a frame, and runs it through the same detection → tracking → line-crossing pipeline used by Feature 1.

---

## Two more things to verify (not confirmed — files not provided)

| Item | Why it matters | Failure mode if wrong |
|---|---|---|
| `pubspec.yaml` — is `assets/models/best.tflite` listed under `flutter: assets:`? | `Interpreter.fromAsset()` needs the asset registered to find the file | Throws on load, caught silently by the same `try/catch` pattern as above — model never loads, `_isLoaded` stays `false` |
| `AndroidManifest.xml` / `Info.plist` — camera and storage/media permissions declared? | Camera stream and file picker both require runtime permissions | Denied permission fails silently in the same way — camera preview may not even start, or file picker returns nothing |

---

## Why the app "looks like it's running" despite all this

- The camera preview renders — this doesn't depend on inference at all.
- The yellow virtual line overlay draws — this is pure UI math based on a fixed constant, no detection needed.
- Nothing else in the pipeline (bounding boxes, tracker updates, entry/exit counts) ever executes successfully, because Issues 1 and 2 kill every frame before a valid detection can be produced.
- There is also currently **no bounding-box drawing code** in the overlay painter at all — only the line is drawn — so even after fixing detection, boxes won't appear on screen until that's added.

---

## Fix priority

1. **Issue 1** (camera frame conversion) — blocks everything downstream in live mode.
2. **Issue 2** (output buffer disconnect + hardcoded shape) — independently blocks all detections, even with valid input.
3. Add bounding-box overlay drawing (currently missing) so detections are visible during calibration/testing, per the original spec's UI requirement.
4. **Issue 3** (video processing) — separate, larger effort: needs a real frame-extraction plugin wired into the existing shared pipeline.
5. Verify `pubspec.yaml` asset registration and platform permissions.
