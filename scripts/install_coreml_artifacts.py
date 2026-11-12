#!/usr/bin/env python3
"""Install pinned public Core ML packages from private Releases or legacy CI artifacts.

Only CI's ephemeral GITHUB_TOKEN is used; it never enters the app/resources/logs.
Source photos, repositories' Python code and training checkpoints are not copied.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "2814152339/MAG-Health-App"
DEST = ROOT / "iOS/Ruyuan/Resources/CoreML"
LOCK = ROOT / "docs/models/coreml-artifacts.json"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""): sha.update(data)
    return sha.hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def archive_source(pin):
    """Release bytes are already the pinned inner ZIP; Actions bytes wrap that ZIP.

    Construct the API path ourselves, never authenticate a URL supplied by a lock or redirect.
    A failed Release download must not silently fall back to an expiring Actions artifact.
    """
    source = pin.get("source")
    if "releaseAssetID" in pin or isinstance(source, dict) and source.get("type") == "githubRelease":
        asset_id = pin.get("releaseAssetID")
        if not positive_integer(asset_id): raise ValueError("invalid_release_asset_id")
        suffix = f"/releases/assets/{asset_id}"
        if source is not None:
            if (not isinstance(source, dict) or source.get("type") != "githubRelease"
                    or source.get("repository") != REPO or source.get("assetID") != asset_id
                    or source.get("assetName") != f"Ruyuan-CoreML-{pin['id']}.zip"
                    or source.get("apiURL") != "https://api.github.com/repos/" + REPO + suffix
                    or not positive_integer(source.get("releaseID"))
                    or source.get("releaseID") != pin.get("releaseID")
                    or not isinstance(source.get("tag"), str) or not source["tag"]
                    or source.get("tag") != pin.get("releaseTag")):
                raise ValueError("release_source_identity_mismatch")
        return "release", suffix
    if source is not None: raise ValueError("unsupported_model_archive_source")
    if not positive_integer(pin.get("artifactID")): raise ValueError("invalid_legacy_artifact_id")
    return "actions", f"/actions/artifacts/{pin['artifactID']}/zip"


def public_storage_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        host = (parsed.hostname or "").lower()
        return (parsed.scheme == "https" and parsed.port in (None, 443) and not parsed.username and not parsed.password
                and not parsed.fragment and any(host.endswith(suffix) and host != suffix[1:] for suffix in
                    (".blob.core.windows.net", ".actions.githubusercontent.com", ".githubusercontent.com")))
    except (TypeError, ValueError): return False


def unsigned_response(url):
    # A separate no-redirect opener and a NEW unauthenticated Request at every hop prevent both
    # Authorization forwarding and accidental redirects to arbitrary/private network locations.
    opener = urllib.request.build_opener(NoRedirect())
    for _ in range(5):
        if not public_storage_url(url): raise RuntimeError("unapproved_model_storage_redirect")
        request = urllib.request.Request(url, headers={"User-Agent": "Ruyuan-CoreML-Bundle"})
        try:
            return opener.open(request, timeout=180)
        except urllib.error.HTTPError as error:
            code, location = error.code, error.headers.get("Location")
            error.close()
            if code in (301, 302, 303, 307, 308) and location:
                url = urllib.parse.urljoin(url, location)
                continue
            raise RuntimeError("model_storage_failed_http_" + str(code)) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise RuntimeError("model_storage_network_failed") from None
    raise RuntimeError("too_many_model_storage_redirects")


def github_binary_response(suffix, token):
    # suffix is produced only by archive_source, never by a redirect or an arbitrary source URL.
    if not re.fullmatch(r"/(?:actions/artifacts/[1-9][0-9]*/zip|releases/assets/[1-9][0-9]*)", suffix):
        raise ValueError("invalid_model_api_path")
    # Actions /zip rejects octet-stream with HTTP 415; Release binary download requires it.
    accept = "application/vnd.github+json" if suffix.startswith("/actions/") else "application/octet-stream"
    headers = {"Authorization": "Bearer " + token, "Accept": accept,
               "User-Agent": "Ruyuan-CoreML-Bundle", "X-GitHub-Api-Version": "2022-11-28"}
    req = urllib.request.Request("https://api.github.com/repos/" + REPO + suffix, headers=headers)
    try:
        # GitHub documents both a direct 200 binary response and a 302 storage redirect.
        return urllib.request.build_opener(NoRedirect()).open(req, timeout=60)
    except urllib.error.HTTPError as error:
        code, location = error.code, error.headers.get("Location")
        error.close()
        if code in (301, 302, 303, 307, 308) and location: return unsigned_response(location)
        raise RuntimeError("model_download_authorization_failed_http_" + str(code)) from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        raise RuntimeError("model_download_network_failed") from None


def download_archive(suffix, token, destination, limit):
    try:
        with github_binary_response(suffix, token) as source, destination.open("wb") as output:
            return copy_bounded(source, output, limit)
    except (urllib.error.URLError, TimeoutError, OSError):
        # Do not leak signed URLs, request headers or upstream reason text into CI tracebacks.
        raise RuntimeError("model_download_stream_failed") from None


def safe_files(archive):
    if len(archive.infolist()) > 200: raise ValueError("too_many_artifact_entries")
    names = set()
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        if not info.filename or path.is_absolute() or ".." in path.parts or "\\" in info.filename or ":" in info.filename:
            raise ValueError("unsafe_artifact_member")
        if info.filename in names: raise ValueError("duplicate_artifact_member")
        names.add(info.filename)
        if info.flag_bits & 1: raise ValueError("encrypted_artifact_member")
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED): raise ValueError("unsupported_artifact_compression")
        # Disallow symbolic links even in authenticated build output.
        if (info.external_attr >> 16) & 0o170000 == 0o120000: raise ValueError("artifact_symlink")
        yield info


def copy_bounded(source, destination, limit):
    total = 0
    while True:
        block = source.read(min(4*1024*1024, limit-total+1))
        if not block: return total
        total += len(block)
        if total > limit: raise ValueError("artifact_byte_budget_exceeded")
        destination.write(block)


def installed_files(record):
    key = record["id"]
    return [{**f, "relativePath": key+".mlpackage/"+f["relativePath"].split(key+".mlpackage/", 1)[1]} for f in record["files"]]


def verify_installed(destination, lock, specs):
    manifest = json.loads((destination/"coreml-model-manifest.json").read_text())
    ids = [m["id"] for m in manifest["models"]]
    if manifest["schema"] != 1 or len(ids) != len(set(ids)) or set(ids) != set(specs):
        raise ValueError("incomplete_installed_model_manifest")
    expected_packages = {pin["id"]+".mlpackage" for pin in lock["models"]}
    if {p.name for p in destination.glob("*.mlpackage")} != expected_packages:
        raise ValueError("unexpected_installed_model_package")
    for pin in lock["models"]:
        approved = pin["model"]
        verify_contract(approved, specs)
        record = next(m for m in manifest["models"] if m["id"] == pin["id"])
        if any(record.get(key) != value for key, value in approved.items()):
            raise ValueError("installed_model_differs_from_approved_pin")
        files = installed_files(approved)
        if record.get("installedFiles") != files: raise ValueError("installed_file_manifest_differs_from_approved_pin")
        expected = set()
        for file in files:
            path = PurePosixPath(file["relativePath"])
            if path.is_absolute() or ".." in path.parts or "\\" in file["relativePath"] or ":" in file["relativePath"]:
                raise ValueError("unsafe_installed_file_path")
            target = destination.joinpath(*path.parts)
            if not target.resolve().is_relative_to(destination.resolve()): raise ValueError("installed_file_outside_resources")
            if not target.is_file() or target.stat().st_size != file["bytes"] or digest(target) != file["sha256"]:
                raise ValueError("installed_coreml_digest_mismatch")
            expected.add(path.as_posix())
        actual = {p.relative_to(destination).as_posix() for p in (destination/(pin["id"]+".mlpackage")).rglob("*") if p.is_file()}
        if actual != expected: raise ValueError("unverified_extra_installed_file")
        print("Verified installed package:", pin["id"])


def verify_contract(record, source_specs):
    spec = source_specs[record["id"]]
    weight = next(f for f in spec["files"] if f["name"] == "model.safetensors")
    if record["revision"] != spec["revision"] or record["repository"] != spec["repo"] or record["modelSHA256"] != weight["sha256"]:
        raise ValueError("coreml_source_pin_mismatch")
    if record["package"] != f"models/{record['id']}/{record['id']}.mlpackage":
        raise ValueError("unexpected_package_path")
    if record["inputSize"] != 224 or record["inputName"] != "image" or record["outputName"] != "logits":
        raise ValueError("unexpected_model_contract")


def verify_package(root, record, source_specs):
    verify_contract(record, source_specs)
    expected = set()
    for entry in record["files"]:
        path = PurePosixPath(entry["relativePath"])
        if path.is_absolute() or ".." in path.parts or ":" in str(path) or "\\" in str(path) or not str(path).startswith(record["package"] + "/"):
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
    if len(lock["models"]) != len(specs): raise ValueError("duplicate_coreml_lock_id")
    sources = {}
    for pin in lock["models"]:
        if (not positive_integer(pin.get("archiveBytes")) or pin["archiveBytes"] > 1024**3
                or not isinstance(pin.get("archiveSHA256"), str) or not re.fullmatch(r"[a-f0-9]{64}", pin["archiveSHA256"])):
            raise ValueError("invalid_model_archive_pin")
        verify_contract(pin["model"], specs)
        sources[pin["id"]] = archive_source(pin)
    if check:
        verify_installed(DEST, lock, specs)
        return
    ROOT.joinpath(".build").mkdir(exist_ok=True)
    token = os.environ.get("GITHUB_TOKEN", "")
    with tempfile.TemporaryDirectory(prefix="coreml-install-", dir=ROOT/".build") as temporary:
        temporary = Path(temporary)
        staged = temporary / "resources"; staged.mkdir()
        records = []
        for pin in lock["models"]:
            key = pin["id"]
            if not token: raise RuntimeError("GITHUB_TOKEN_required_for_private_artifact_download")
            inner = temporary / (key + ".zip")
            kind, suffix = sources[key]
            if kind == "release":
                download_archive(suffix, token, inner, pin["archiveBytes"])
            else:
                outer = temporary / (key + "-action.zip")
                download_archive(suffix, token, outer, pin["archiveBytes"] + 2_000_000)
                with zipfile.ZipFile(outer) as archive:
                    entries = [i for i in safe_files(archive) if i.filename.endswith("Ruyuan-CoreML-" + key + ".zip")]
                    if len(entries) != 1: raise ValueError("missing_verified_model_archive")
                    if entries[0].file_size != pin["archiveBytes"]: raise ValueError("wrong_model_archive_size")
                    with archive.open(entries[0]) as source, inner.open("wb") as destination:
                        copy_bounded(source, destination, pin["archiveBytes"])
            if inner.stat().st_size != pin["archiveBytes"] or digest(inner) != pin["archiveSHA256"]:
                raise ValueError("coreml_archive_digest_mismatch")
            extracted = temporary / key; extracted.mkdir()
            with zipfile.ZipFile(inner) as archive:
                entries = list(safe_files(archive))
                if sum(i.file_size for i in entries) > 430_000_000: raise ValueError("oversize_model_archive")
                archive.extractall(extracted, members=entries)
            manifest = json.loads((extracted/"model-manifest.json").read_text())
            if manifest["schema"] != 1 or manifest["state"] != "converted_and_coreml_cpu_verified" or len(manifest["models"]) != 1:
                raise ValueError("unverified_conversion")
            record = manifest["models"][0]
            if record["id"] != key: raise ValueError("wrong_model_artifact")
            if record != pin["model"]: raise ValueError("artifact_model_differs_from_approved_pin")
            verify_package(extracted, record, specs)
            shutil.copytree(extracted/record["package"], staged/(key+".mlpackage"))
            shutil.copytree(extracted/"models"/key/"source-notices", staged/"source-notices"/key)
            record["installedFiles"] = installed_files(pin["model"])
            record["validation"] = pin["validation"]
            records.append(record)
            print("Installed hash-verified trained model:", key)
        (staged/"coreml-model-manifest.json").write_text(json.dumps({"schema": 1, "models": records}, indent=2)+"\n", encoding="utf-8")
        expected = (ROOT/"iOS/Ruyuan/Resources").resolve()/"CoreML"
        if not expected.is_relative_to(ROOT.resolve()) or DEST.resolve() != expected: raise RuntimeError("unexpected_destination")
        if DEST.exists():
            # Only this exact generated model directory, never any other source/resource.
            shutil.rmtree(DEST)
        shutil.copytree(staged, DEST)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--lock", type=Path, default=LOCK)
    args = parser.parse_args()
    try:
        install(args.lock, args.check)
    except Exception as error:
        # Fixed local error codes only. Never print upstream reason text, URLs or headers.
        code = str(error)
        if not isinstance(error, (RuntimeError, ValueError)) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", code):
            code = "coreml_install_failed_no_secret_details_logged"
        raise SystemExit(code) from None
