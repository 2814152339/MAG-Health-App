#!/usr/bin/env python3
"""Verify the exact standalone model actually converted and tested in macOS CI."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "iOS/Ruyuan/Resources/Models"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
parser.parse_args()
manifest = json.loads((FOLDER/"PoreNet-resource-manifest.json").read_text())
resource = manifest["resource"]
assert manifest["state"] == "converted_and_coreml_cpu_verified"
assert resource["fileName"] == "PoreNet.mlmodel"
assert resource["bytes"] == 20579
assert resource["sha256"] == "30a8f1e7dc88ae540769c90d9527c3bd93b13f149b748652d0ff14ab390a129c"
assert resource["outputShape"] == [1, 1, 1280, 1024]
assert resource["revision"] == "6f851e0d911bd73f41dd905c685129b13d52e1bc"
model = FOLDER / resource["fileName"]
assert model.stat().st_size == resource["bytes"]
assert hashlib.sha256(model.read_bytes()).hexdigest() == resource["sha256"]
assert hashlib.sha256((FOLDER/"LICENSE-PoreNet.txt").read_bytes()).hexdigest() == "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"
print("Verified Pore-Net:", resource["bytes"], "bytes; actual Core ML pixel parity recorded; SHA256", resource["sha256"])
