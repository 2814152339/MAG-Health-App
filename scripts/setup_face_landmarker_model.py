#!/usr/bin/env python3
"""Fetch/check only the pinned official Apache-2.0 FaceLandmarker task bundle.

The .bin resource is byte-for-byte the official .task ZIP; no model conversion.
CI should use --check, with absent/corrupt weights a failure, never a fake fallback.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "iOS/Ruyuan/Resources/Models/face_landmarker.bin"
URL = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
SIZE = 3_758_596
LICENSE = MODEL.with_name("FaceLandmarker-APACHE-2.0.txt")
LICENSE_SHA256 = "8707eef0533987efc5b155d64761eeb6e20793f50b9bd1a68dad1cf4719d0ed8"
FILES = {"face_detector.tflite", "face_landmarks_detector.tflite", "geometry_pipeline_metadata_landmarks.binarypb", "face_blendshapes.tflite"}


def verify(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"Required real FaceLandmarker model missing: {path}")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != SIZE or digest != SHA256:
        raise SystemExit(f"FaceLandmarker integrity FAILED: bytes={len(data)}, sha256={digest}")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if set(archive.namelist()) != FILES:
            raise SystemExit("Unexpected official task bundle contents")
    print(f"Verified official FaceLandmarker: {len(data)} bytes; SHA256 {digest}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Require the existing exact model; never download or replace")
    args = parser.parse_args()
    if not LICENSE.is_file() or hashlib.sha256(LICENSE.read_bytes()).hexdigest() != LICENSE_SHA256:
        raise SystemExit("Required bundled Apache-2.0 model license missing or altered")
    if args.check or MODEL.exists():
        verify(MODEL)
        return
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    temporary = MODEL.with_suffix(".download")
    try:
        request = urllib.request.Request(URL, headers={"User-Agent": "RuyuanAesthetics-model-setup/1"})
        with urllib.request.urlopen(request, timeout=120) as response:
            if response.geturl() != URL:
                raise SystemExit("Unexpected model redirect")
            with temporary.open("wb") as destination:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > SIZE:
                        raise SystemExit("Official model download exceeds pinned size")
                    destination.write(chunk)
        verify(temporary)
        os.replace(temporary, MODEL)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
