# Crowd Detection App — Complete Build Specification
### For: Coding Agent Implementation
### Project: Buzing.lk — Bus Doorway Crowd Counter (Flutter)

---

## 1. Project Overview

Build a Flutter mobile app that detects and counts people entering/exiting a bus through a doorway, using a custom fine-tuned YOLOv8n object detection model running entirely on-device (no cloud inference).

**Two features required in this version:**
1. **Live Camera Detection** — real-time counting from the phone's live camera feed
2. **Video Upload Detection** — process a pre-recorded video file and return a people count

**Explicitly out of scope for this version** (to be specified separately later):
- Firebase Authentication
- Backend/API integration for syncing counts
- Multi-door (front+back) combination logic
- Any dedicated IoT/hardware integration

---

## 2. The Trained Model

- **Base model:** YOLOv8n (nano) — Ultralytics
- **Fine-tuned on:** 230 labeled images of real bus-doorway footage (PCDS academic dataset + custom-recorded footage), covering 4 conditions: normal-lighting/crowded, normal-lighting/uncrowded, noisy-lighting/crowded, noisy-lighting/uncrowded
- **Training:** 50 epochs, image size 320×320, on Google Colab (T4 GPU)
- **Validation results (held-out validation set, 46 images):**
  - Precision: 0.837
  - Recall: 0.822
  - mAP50: 0.862
  - mAP50-95: 0.507
- **Exported format:** TFLite (internally now branded "LiteRT" by Ultralytics as of recent versions — same file format, fully compatible)
- **File:** `best.tflite` — 11.6 MB
- **Input size:** 320×320 (RGB)
- **Classes:** 1 (`person`)
- **Known limitation:** accuracy drops during simultaneous multi-person crossings (heavy occlusion) — this is an accepted, stated limitation of single-camera line-crossing counting, not a bug to "fix" in this version.

**Model file location:** the agent should expect `best.tflite` to be provided and placed at `assets/models/best.tflite` in the Flutter project. Register it in `pubspec.yaml` under `flutter: assets:`.

---

## 3. Core Concept: How Counting Actually Works

This is the most important section — read carefully before implementing.

**The model only detects "a person exists here, in this frame."** It has no concept of direction, movement, or counting. Direction and counting logic must be built entirely in application code, on top of raw detections, using the following method:

### 3.1 The Virtual Line
Define a fixed line across the camera frame representing the doorway threshold (e.g., a horizontal line at 60% of frame height — exact position must be configurable/calibratable since it depends on physical camera mounting angle).

```dart
final double lineY = frameHeight * 0.6; // adjustable/calibratable constant
```

Anything on one side = "outside the bus," the other side = "inside the bus."

### 3.2 Per-Frame Detection
For each frame, run inference and get a list of bounding boxes (one per detected person). Compute each box's centroid:
```dart
double centroidY = (box.top + box.bottom) / 2;
```

### 3.3 Tracking (Critical — Do Not Skip)
Detections alone are NOT enough — you must track each individual person across consecutive frames to know it's the same person, not a new one. Implement a **centroid tracker**:

- Maintain a list of `TrackedPerson` objects, each with an ID and last known centroid position
- For each new frame's detections, match each detection to the closest existing tracked person (based on centroid distance) within a reasonable threshold distance
- If no existing tracked person is close enough, create a new tracked person with a new ID
- If an existing tracked person has no matching detection this frame, do NOT immediately delete them — allow a **grace period of ~3 frames** before dropping the track (handles brief occlusion/detection flicker without causing false crossings)

```dart
class TrackedPerson {
  final int id;
  double lastCentroidY;
  String? lastSide; // "outside" or "inside" or null (not yet determined)
  int framesSinceLastSeen = 0;
}
```

### 3.4 Line-Crossing Detection & Counting
For each tracked person, each frame:
```dart
String currentSide = centroidY < lineY ? "outside" : "inside";

if (trackedPerson.lastSide != null && trackedPerson.lastSide != currentSide) {
  if (trackedPerson.lastSide == "outside" && currentSide == "inside") {
    occupancyCount += 1;
    logEvent(direction: "entry", personId: trackedPerson.id, timestamp: now);
  } else if (trackedPerson.lastSide == "inside" && currentSide == "outside") {
    occupancyCount -= 1;
    logEvent(direction: "exit", personId: trackedPerson.id, timestamp: now);
  }
}

trackedPerson.lastSide = currentSide;
```

That is the entire counting mechanism. The "+1 / -1" logic is trivial — the complexity lives entirely in reliable tracking (3.3), not in the counting itself.

### 3.5 Known Failure Mode (Accept, Don't Over-Engineer)
Simultaneous multi-person crossings (a crowd pushing through at once) can cause undercounting since heavily overlapping people may be detected as fewer boxes than actual people present. Do not attempt to solve this in this version — log it as a known limitation. A future version would address this with multi-camera fusion (out of scope here).

---

## 4. Feature 1: Live Camera Detection

### 4.1 Functional Requirements
- Open rear-facing camera, display live preview
- Run detection pipeline (Section 3) continuously on the live feed
- Maintain and display running occupancy count for the current session
- Provide Start/Stop session controls
- Provide a Door selector (Front / Back) — tags which physical door this session's data represents (relevant for later backend integration, but capture it now)

### 4.2 UI Requirements
- Full-screen camera preview
- Overlay: bounding boxes drawn on detected people (for visual verification during testing/calibration)
- Overlay: visible virtual line indicator, so the phone can be physically positioned correctly at the doorway
- On-screen counter display: `Entries: X | Exits: Y | Occupancy: Z`
- Start / Stop buttons
- Door selector (Front/Back toggle or dropdown)

### 4.3 Technical Requirements
- Camera access via the `camera` Flutter package
- Frame preprocessing: resize to 320×320, convert to RGB, normalize pixel values to match model's expected input format (confirm exact normalization range — typically 0–1 float — against the exported model's requirements)
- Run inference on every 2nd or 3rd frame (not every frame) for performance/battery balance — this is sufficient since a person cannot fully cross a doorway within 1-2 frames
- Perform preprocessing and inference on a background isolate if possible, to avoid blocking the UI thread and causing dropped camera frames
- Apply confidence threshold filtering (start at ~0.4–0.5, make this a tunable constant for easy adjustment during testing) and Non-Max Suppression to raw model output before passing to the tracker

---

## 5. Feature 2: Video Upload Detection

### 5.1 Functional Requirements
- User selects a video file from device storage via a file picker
- App extracts frames from the video at a set interval (not every frame — same sampling philosophy as live mode, tunable constant)
- Runs the identical detection → tracking → line-crossing pipeline (Section 3) against the extracted frame sequence, in order, simulating a live session
- Displays final summary results after processing completes

### 5.2 UI Requirements
- "Select Video" button (native file picker)
- Processing state: progress indicator showing frames processed / total frames
- Results screen after completion: total entries, total exits, net occupancy change, video duration processed
- Allow re-selecting/re-processing a different video from the results screen

### 5.3 Technical Requirements
- Video frame extraction: research and select an appropriate Flutter-compatible approach for extracting frames from a video file at a set interval (options to evaluate: a video-thumbnail/frame-extraction plugin, or FFmpeg-based extraction if a suitable plugin proves unreliable) — validate this works reliably on-device before building the rest of this feature around it, since Flutter's video-processing plugin ecosystem can be inconsistent across Android/iOS
- Processing must happen entirely on-device (no video upload to any external service)
- Reuse the exact same detection/tracking/line-crossing code from Feature 1 — do not duplicate this logic; structure it as shared, reusable functions/classes called by both features, differing only in frame source

---

## 6. Shared Architecture

```
Frame Source (live camera stream OR extracted video frames)
        ↓
Frame Preprocessing (resize 320×320, RGB, normalize)
        ↓
YOLO Inference (best.tflite via tflite_flutter)
        ↓
Post-processing (confidence threshold filter + Non-Max Suppression)
        ↓
Person Tracker (centroid tracking, grace-period frame persistence)
        ↓
Line-Crossing Detector (virtual line position check + side-flip → direction)
        ↓
Event Log (list of {direction, personId, timestamp})
        ↓
Feature 1: live running counter UI update
Feature 2: aggregate into final summary results
```

---

## 7. Required Flutter Packages

| Package | Purpose |
|---|---|
| `camera` | Live camera feed access (Feature 1) |
| `tflite_flutter` | Load and run the `.tflite` model |
| `image` | Frame preprocessing (resize, format conversion) |
| `file_picker` | Video file selection (Feature 2) |
| Video frame extraction package | TBD — evaluate options during implementation (see Section 5.3) |

---

## 8. Suggested Project Structure

```
lib/
  crowd_detection/
    camera_service.dart          # Live camera stream capture (Feature 1)
    video_frame_extractor.dart   # Video file → frame sequence (Feature 2)
    frame_preprocessor.dart      # Shared: resize/normalize/format conversion
    yolo_detector.dart           # Shared: model loading + inference + NMS
    person_tracker.dart          # Shared: centroid tracker (Section 3.3)
    line_crossing.dart           # Shared: virtual line + direction logic (Section 3.4)
    live_detection_screen.dart   # Feature 1 UI
    video_upload_screen.dart     # Feature 2 UI
  models/
    detection_event.dart         # Data class: {direction, personId, timestamp}
    tracked_person.dart          # Data class: TrackedPerson (Section 3.3)
assets/
  models/
    best.tflite
```

---

## 9. Testing Checklist Before Considering This Feature Complete

- [ ] Model loads successfully and runs inference on a live camera frame (bounding boxes visible and reasonably accurate)
- [ ] Tracker maintains a consistent ID for a single person walking across the frame (does not create duplicate IDs for the same person)
- [ ] Tracker survives brief occlusion (person briefly blocked/undetected for 1-2 frames) without creating a false crossing
- [ ] Walking through the virtual line in one direction correctly logs an entry; the other direction correctly logs an exit
- [ ] Occupancy count updates correctly and matches manual verification (walk through a known number of times, confirm the count matches)
- [ ] Video upload mode produces the same result as live mode when tested against a recording of the same physical walkthrough
- [ ] Tested explicitly with 2+ people crossing close together — document actual behavior (expected to be a known weak point, not expected to be perfect)
- [ ] App remains responsive (camera preview doesn't freeze/lag) during continuous live detection

---

## 10. Explicitly Deferred (Do Not Build Yet)

- Firebase Authentication — to be specified in a follow-up spec
- Backend API sync of entry/exit events — to be specified in a follow-up spec once backend integration details are finalized
- Combining front-door and back-door counts into one total occupancy — this will happen at the backend level once both phones' data is being synced
