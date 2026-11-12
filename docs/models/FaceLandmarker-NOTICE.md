# Bundled Google FaceLandmarker 478-point model

This app redistributes the unmodified official model bundle under Apache License 2.0.
`FaceLandmarker-APACHE-2.0.txt` is packaged with the app. The `.bin` resource is only
a filename change from `.task` to avoid Xcode resource-rule ambiguity; its bytes are unchanged.

- Official versioned download: <https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task>
- Resource: `iOS/Ruyuan/Resources/Models/face_landmarker.bin`
- Bytes: 3,758,596
- SHA-256: `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff`
- ZIP entries: `face_detector.tflite`, `face_landmarks_detector.tflite`,
  `geometry_pipeline_metadata_landmarks.binarypb`, `face_blendshapes.tflite`.
- No external training dataset is redistributed. The optional blendshape/matrix outputs are disabled.

## Model-weight license evidence

The [official task overview](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
links these Google model cards. All three cards were downloaded and their text read locally;
each explicitly lists **Apache License, Version 2.0** under “LICENSED UNDER”. This is
weight-license evidence, not an inference from the SDK source-code license.

1. [Face Mesh V2 model card](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf),
   SHA-256 `c6add060f4ebfb37b2690136b6c711c7e5fcb7038baa2649ae3338b83979565a`.
2. [BlazeFace short-range model card](https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20%28Short%20Range%29.pdf),
   SHA-256 `cd335c06fc0de7807cd815a0777a697932598bcdb28fa98adaaabf847485f758`.
3. [Blendshape V2 model card](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Blendshape%20V2.pdf),
   SHA-256 `c8e9cf60a39998f4b341740623917590e050d1c97004e2de4568d84e026445ae`.

## Coordinates, topology and evidence boundaries

Inference uses MediaPipe Tasks Vision 1.2.2 on CPU, pinned through the existing official
MediaPipe SPM package. The exact SDK headers were checked for the Swift option/method names.
Connections are obtained from the SDK `FaceLandmarker` connection arrays at runtime, not
handwritten remembered index lists. The corresponding official Apache-licensed index source is
[`MPPFaceLandmarksConnections.h` at pinned revision 3c49477cd79f753fbe943d814b917e3c8c0bf404](https://github.com/google-ai-edge/mediapipe/blob/3c49477cd79f753fbe943d814b917e3c8c0bf404/mediapipe/tasks/ios/vision/face_landmarker/sources/MPPFaceLandmarksConnections.h).

- The 478 observed model points use the upright full photograph, normalized X/Y, top-left origin.
- Model-relative Z is **not measured depth or millimeters** and is never used for metric geometry.
- Named model paths have `mp-` prefixes and do not replace the existing Vision canonical regions.
- Iris rings are not relabeled as pupil centers. No bone, anatomical hairline, identity or medical claim is made.
- One dense `.points` path and official contour edges yield 145 additional paths / 1,356 points /
  two overlay layers in total, including the independent landmark paths. No tessellation explosion.
- Missing/invalid model, no face, multiple faces or out-of-bounds points throw explicit errors;
  no zero-filled, clamped or synthesized landmarks are returned as actual detections.
- `scripts/setup_face_landmarker_model.py --check` requires exact weights and the bundled license.
  Production CI must require it. `FaceLandmarkServiceTests` invokes the actual model on a blank
  RGBA image and requires a real no-face response; broken or missing inference is not skipped.

## Local-only smoke evidence

On 2026-11-12, the actual `.bin` was invoked with MediaPipe Python 1.2.2 CPU on Windows:
blank input returned zero faces; an unannotated face crop from the user-provided reference video
returned one face and exactly 478 finite, in-bounds points. Graph creation plus both calls took
approximately 0.045 seconds on that host; **this is not an iPhone benchmark or device-capture test**.
The private crop/output stayed under ignored `.build/`, were not uploaded and are not bundled.
The iOS XCTest/device build is a separate CI gate, not established by this Windows smoke test.
