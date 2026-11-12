#!/usr/bin/env python3
"""Fetch/verify only the official, redistributable Google model; no private images involved.

CI must run with --check before packaging. Runtime fallback is not a production delivery substitute.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "iOS/Ruyuan/Resources/Models/selfie_multiclass_256x256.tflite"
URL = "https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/1/selfie_multiclass_256x256.tflite"
SHA256 = "c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0"
SIZE = 16_371_837
LICENSE = MODEL.with_name("SelfieMulticlass-APACHE-2.0.txt")
LICENSE_SHA256 = "8707eef0533987efc5b155d64761eeb6e20793f50b9bd1a68dad1cf4719d0ed8"


def verify(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"Required real segmentation model is missing: {path}")
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != SIZE or digest != SHA256 or data[4:8] != b"TFL3":
        raise SystemExit(f"Segmentation model integrity FAILED: bytes={len(data)}, sha256={digest}")
    print(f"Verified official Selfie Multiclass: {len(data)} bytes; SHA256 {digest}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Require existing exact weights; never download or silently replace")
    args = parser.parse_args()
    if not LICENSE.is_file() or hashlib.sha256(LICENSE.read_bytes()).hexdigest() != LICENSE_SHA256:
        raise SystemExit("Required bundled Apache-2.0 model license is missing or altered")
    if args.check or MODEL.exists():
        verify(MODEL)
        return
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    temporary = MODEL.with_suffix(".download")
    try:
        request = urllib.request.Request(URL, headers={"User-Agent": "RuyuanAesthetics-model-setup/1"})
        with urllib.request.urlopen(request, timeout=120) as response:
            if response.geturl() != URL:
                raise SystemExit("Unexpected model download redirect; refusing unverified source")
            with temporary.open("wb") as destination:
                while chunk := response.read(1024 * 1024):
                    destination.write(chunk)
        verify(temporary)
        os.replace(temporary, MODEL)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
