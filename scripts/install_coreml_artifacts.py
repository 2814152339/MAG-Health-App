#!/usr/bin/env python3
"""Install hash-pinned, verified public Core ML packages from private CI artifacts.

Only CI's ephemeral GITHUB_TOKEN is used; it never enters the app/resources/logs.
Source photos, repositories' Python code and training checkpoints are not copied.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "2814152339/ruyuan-aesthetics-ios"
DEST = ROOT / "iOS/Ruyuan/Resources/CoreML"
LOCK = ROOT / "docs/models/coreml-artifacts.json"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""): sha.update(data)
    return sha.hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


def request_artifact(artifact_id, token):
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "User-Agent": "Ruyuan-CoreML-Bundle", "X-GitHub-Api-Version": "2022-11-28"}
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/actions/artifacts/{artifact_id}/zip", headers=headers)
    try:
        urllib.request.build_opener(NoRedirect()).open(req, timeout=45)
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308): return error.headers["Location"]
        raise RuntimeError("artifact_download_authorization_failed:" + str(error.code)) from None
    raise RuntimeError("expected_signed_artifact_redirect")


def safe_files(archive):
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        if path.is_absolute() or ".." in path.parts or "\\" in info.filename:
            raise ValueError("unsafe_artifact_member")
        # Disallow symbolic links even in authenticated build output.
        if (info.external_attr >> 16) & 0o170000 == 0o120000: raise ValueError("artifact_symlink")
        yield info


def verify_package(root, record, source_specs):
    spec = source_specs[record["id"]]
    weight = next(f for f in spec["files"] if f["name"] == "model.safetensors")
    if record["revision"] != spec["revision"] or record["repository"] != spec["repo"] or record["modelSHA256"] != weight["sha256"]:
        raise ValueError("coreml_source_pin_mismatch")
    if record["package"] != f"models/{record['id']}/{record['id']}.mlpackage":
        raise ValueError("unexpected_package_path")
    if record["inputSize"] != 224 or record["inputName"] != "image" or record["outputName"] != "logits":
        raise ValueError("unexpected_model_contract")
    expected = set()
    for entry in record["files"]:
        path = PurePosixPath(entry["relativePath"])
        if path.is_absolute() or ".." in path.parts or not str(path).startswith(record["package"] + "/"):
            raise ValueError("unexpected_package_file")
        file = root.joinpath(*path.parts)
        if not file.is_file() or file.stat().st_size != entry["bytes"] or digest(file) != entry["sha256"]:
            raise ValueError("coreml_package_digest_mismatch")
        expected.add(path.as_posix())
    actual = {p.relative_to(root).as_posix() for p in (root/record["package"]).rglob("*") if p.is_file()}
    if actual != expected: raise ValueError("unexpected_unverified_package_file")


def install(lock_path=LOCK, check=False):
    if not lock_path.exists():
        if check: raise RuntimeError("coreml_artifact_lock_missing")
        print("No approved Core ML artifact lock; no model downloads performed.")
        return
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    specs = {s["id"]: s for s in json.loads((ROOT/"backend/ruyuan/skin_model_manifest.json").read_text())["models"]}
    if lock["schema"] != 1 or {m["id"] for m in lock["models"]} != set(specs):
        raise ValueError("incomplete_coreml_lock")
    ROOT.joinpath(".build").mkdir(exist_ok=True)
    token = os.environ.get("GITHUB_TOKEN", "")
    with tempfile.TemporaryDirectory(prefix="coreml-install-", dir=ROOT/".build") as temporary:
        temporary = Path(temporary)
        staged = temporary / "resources"; staged.mkdir()
        records = []
        for pin in lock["models"]:
            key = pin["id"]
            if check:
                manifest = json.loads((DEST/"coreml-model-manifest.json").read_text())
                record = next(m for m in manifest["models"] if m["id"] == key)
                for file in record["installedFiles"]:
                    target = DEST / file["relativePath"]
                    if not target.is_file() or target.stat().st_size != file["bytes"] or digest(target) != file["sha256"]:
                        raise ValueError("installed_coreml_digest_mismatch")
                print("Verified installed package:", key)
                continue
            if not token: raise RuntimeError("GITHUB_TOKEN_required_for_private_artifact_download")
            outer = temporary / (key + "-action.zip")
            url = request_artifact(int(pin["artifactID"]), token)
            # New request intentionally does NOT forward GitHub Authorization to storage.
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Ruyuan-CoreML-Bundle"}), timeout=180) as source, outer.open("wb") as destination:
                shutil.copyfileobj(source, destination, 4*1024*1024)
            inner = temporary / (key + ".zip")
            with zipfile.ZipFile(outer) as archive:
                entries = [i for i in safe_files(archive) if i.filename.endswith("Ruyuan-CoreML-" + key + ".zip")]
                if len(entries) != 1: raise ValueError("missing_verified_model_archive")
                with archive.open(entries[0]) as source, inner.open("wb") as destination:
                    shutil.copyfileobj(source, destination, 4*1024*1024)
            if inner.stat().st_size != pin["archiveBytes"] or digest(inner) != pin["archiveSHA256"]:
                raise ValueError("coreml_archive_digest_mismatch")
            extracted = temporary / key; extracted.mkdir()
            with zipfile.ZipFile(inner) as archive:
                entries = list(safe_files(archive))
                if sum(i.file_size for i in entries) > 230_000_000: raise ValueError("oversize_model_archive")
                archive.extractall(extracted, members=entries)
            manifest = json.loads((extracted/"model-manifest.json").read_text())
            if manifest["schema"] != 1 or manifest["state"] != "converted_and_coreml_cpu_verified" or len(manifest["models"]) != 1:
                raise ValueError("unverified_conversion")
            record = manifest["models"][0]
            if record["id"] != key: raise ValueError("wrong_model_artifact")
            verify_package(extracted, record, specs)
            shutil.copytree(extracted/record["package"], staged/(key+".mlpackage"))
            shutil.copytree(extracted/"models"/key/"source-notices", staged/"source-notices"/key)
            record["installedFiles"] = [{**f, "relativePath": key+".mlpackage/"+f["relativePath"].split(key+".mlpackage/", 1)[1]} for f in record["files"]]
            record["validation"] = pin["validation"]
            records.append(record)
            print("Installed hash-verified trained model:", key)
        if check: return
        (staged/"coreml-model-manifest.json").write_text(json.dumps({"schema": 1, "models": records}, indent=2)+"\n", encoding="utf-8")
        if DEST.resolve().parent != (ROOT/"iOS/Ruyuan/Resources").resolve(): raise RuntimeError("unexpected_destination")
        if DEST.exists():
            # Only this exact generated model directory, never any other source/resource.
            shutil.rmtree(DEST)
        shutil.copytree(staged, DEST)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--lock", type=Path, default=LOCK)
    args = parser.parse_args()
    install(args.lock, args.check)
