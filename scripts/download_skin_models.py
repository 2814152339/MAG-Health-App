#!/usr/bin/env python3
"""Fetch only pinned public inference files. Never reads/uploads user photographs.

Default source is the author repositories on huggingface.co. The explicit
--endpoint=https://hf-mirror.com option is a transport fallback; the manifest
still identifies author revisions and verifies every file, including LFS SHA256.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "backend/ruyuan/skin_model_manifest.json"
ENDPOINTS = {"https://huggingface.co", "https://hf-mirror.com"}


def verify(path: Path, spec: dict) -> bool:
    if not path.is_file() or path.stat().st_size != spec["bytes"]:
        return False
    sha256 = hashlib.sha256()
    blob = hashlib.sha1(f"blob {spec['bytes']}\0".encode())
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha256.update(chunk); blob.update(chunk)
    return sha256.hexdigest() == spec["sha256"] if spec.get("sha256") else blob.hexdigest() == spec["git_blob_sha1"]


def download_one(model: dict, spec: dict, root: Path, endpoint: str, attempts: int = 3) -> dict:
    folder = root / model["id"] / model["revision"]
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / spec["name"]
    if verify(path, spec):
        return {"model": model["id"], "file": spec["name"], "state": "verified_existing"}
    partial = path.with_name(path.name + ".part")
    url = f"{endpoint}/{model['repo']}/resolve/{model['revision']}/{urllib.parse.quote(spec['name'])}?download=true"
    for attempt in range(attempts):
        try:
            start = partial.stat().st_size if partial.exists() else 0
            if start > spec["bytes"]:
                partial.unlink(); start = 0
            if start == spec["bytes"]:
                if verify(partial, spec):
                    os.replace(partial, path)
                    return {"model":model["id"],"file":spec["name"],"state":"verified_resumed"}
                partial.unlink(); start = 0
            headers = {"User-Agent": "Ruyuan-Pinned-Public-Model-Downloader/1.0"}
            if start: headers["Range"] = f"bytes={start}-"
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=90) as response:
                append = start > 0 and response.status == 206
                if append and not response.headers.get("Content-Range", "").startswith(f"bytes {start}-"):
                    raise ValueError("invalid_content_range")
                total = start if append else 0
                with partial.open("ab" if append else "wb") as target:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk: break
                        total += len(chunk)
                        if total > spec["bytes"]: raise ValueError("download_exceeds_pinned_size")
                        target.write(chunk)
            if not verify(partial, spec):
                partial.unlink(missing_ok=True)
                raise ValueError("pinned_digest_or_size_mismatch")
            os.replace(partial, path)
            return {"model":model["id"],"file":spec["name"],"state":"downloaded_verified","bytes":spec["bytes"]}
        except (OSError, ValueError, urllib.error.URLError) as error:
            if attempt + 1 == attempts:
                # No signed redirect URL or local private path goes into the receipt/error.
                raise RuntimeError(f"{model['id']}/{spec['name']}: {type(error).__name__}") from None
            time.sleep(2 ** attempt)
    raise RuntimeError("unreachable")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / "backend/models/skin")
    parser.add_argument("--endpoint", choices=sorted(ENDPOINTS), default="https://huggingface.co")
    parser.add_argument("--models", nargs="+", choices=["acne","wrinkles","skin_type"], default=["acne","wrinkles","skin_type"])
    parser.add_argument("--workers", type=int, choices=[1,2,3], default=2)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    models = [m for m in manifest["models"] if m["id"] in args.models]
    jobs = [(m,s) for m in models for s in m["files"]]
    receipt = {"schema":1,"transport":args.endpoint,"sourceManifestSHA256":hashlib.sha256(MANIFEST.read_bytes()).hexdigest(),"files":[]}
    args.destination.mkdir(parents=True, exist_ok=True)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(download_one,m,s,args.destination,args.endpoint) for m,s in jobs]
            for completed in concurrent.futures.as_completed(futures):
                record = completed.result(); receipt["files"].append(record)
                print(json.dumps(record), flush=True)
    except RuntimeError as error:
        print(str(error), file=sys.stderr); return 1
    receipt["state"] = "all_pinned_files_verified"
    (args.destination/"download-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n",encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
