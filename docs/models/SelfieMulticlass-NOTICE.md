# Google Selfie Multiclass on-device model

- Weight: `iOS/Ruyuan/Resources/Models/selfie_multiclass_256x256.tflite`
- Official, versioned URL: https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite
- 16,371,837 bytes; SHA-256 `c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0` (downloaded and independently hashed).
- Model author: Google (Adel Ahmadyan), May 10, 2023. The official model card explicitly licenses the model under Apache License 2.0; full license distributed alongside the weight.
- Original model card: https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Multiclass%20Segmentation.pdf
- Saved model-card SHA-256: `59372fce0666d4c75b3877540fa77f80ac4b2a0f75e914711417f85fc490a9e6`.
- Runtime: official https://github.com/google-ai-edge/mediapipe at revision `3c49477cd79f753fbe943d814b917e3c8c0bf404`, SwiftPM product `MediaPipeTasksVision`, CPU image mode. Package snapshot `mediapipe-Package.swift` SHA-256 `9ce94e89138b4bf4a3f18d0b4bdc7b51b1600c1dd270d46ece52c546a3b60c61`.
- Source/API documentation: https://ai.google.dev/edge/mediapipe/solutions/vision/image_segmenter and https://ai.google.dev/edge/mediapipe/solutions/setup_ios

## Real inference contract

The model receives a canonical upright RGB image through MediaPipe Tasks, which performs its documented 256×256 preprocessing. All six full-resolution output confidence maps and the category map are copied before releasing the native task. Official class IDs: 0 background; 1 hair; 2 body-skin; 3 face-skin; 4 clothes; 5 accessories/others. Face sampling requires category 3 and probability ≥0.65, intersects the user's Vision face ROI, and still excludes eye, eyebrow, lip and nostril regions from the same user's landmarks. No video, source image or mask is transmitted or retained by the service.

The model separates visible surfaces; it does **not** detect skin diseases, pore pathology, hydration, sensitivity, anatomical hair follicles or bone geometry. Existing appearance formulas remain labeled photo heuristics. Visible hair-to-forehead transitions only generate three vertical proportions when at least 7 of 11 central columns agree within 4.5% of detected face height; they are labeled visible-boundary ratios, not an anatomical hairline. Bangs, wigs, makeup and occlusion can change the result. Unsupported boundaries remain absent and manual confirmation stays available.

If a model is absent, corrupt or inference fails, reports explicitly state that no semantic result was produced, show a failed quality check and identify geometric-ROI fallback in provenance. **Shipping CI must require `python3 scripts/setup_segmentation_model.py --check` and the real inference XCTest to pass.** Fallback is only transparent fault handling, not successful model delivery.

## Reproducibility and privacy

`python scripts/setup_segmentation_model.py` fetches only the versioned Google weight and rejects byte-count/checksum mismatches. `--check` never fetches or replaces. The official SPM package verifies its hosted xcframework checksums; its dependency binaries are not copied into this repository. Tests include actual CPU inference on a generated blank raster, category/uncertainty checks, geometric feature exclusions and genuine boundary calculations with synthetic masks. A private portrait may be tested **locally only** under ignored `.build/`/`private-data/`; never commit a private portrait, inference mask or identifying output. Windows Python inference is a separate smoke test and does not by itself prove iOS device performance or quality.
