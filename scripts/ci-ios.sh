#!/bin/bash
# No signing credentials or private photos; pinned public models and SDKs are fetched in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${CI_ARTIFACTS_DIR:-$ROOT/.build/ci/$(date +%Y%m%d-%H%M%S)-$$}"
DERIVED="$ROOT/.build/ci-derived"
if [[ -e "$OUT" && ! -d "$OUT" ]] || \
   [[ -d "$OUT" && -n "$(ls -A "$OUT")" ]]; then
  echo 'Use a fresh empty CI_ARTIFACTS_DIR; refusing to mix this run with old results.'
  exit 1
fi
mkdir -p "$OUT"
BUILD_STATUS=not_run
TEST_STATUS=not_run
ATTACHMENT_STATUS=not_run
RECORDING_STATUS=not_run
RECORDER_PID=""
RECORDING_APP_LAUNCHED=0
DEVICE=""
BOOTED_BY_SCRIPT=0

# tee must not hide xcodebuild failures. Capture both statuses before any command
# can overwrite PIPESTATUS; retain the compiler's exit code in preference to tee.
run_logged() {
  local name="$1"
  shift
  local statuses
  set +e
  "$@" 2>&1 | tee "$OUT/$name.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "${statuses[0]}" -ne 0 ]]; then
    return "${statuses[0]}"
  fi
  return "${statuses[1]}"
}

# Signal only the recorder that this script started. SIGINT lets simctl finish
# the MP4 index; bounded escalation also covers launch failure and CI cancel.
# Bash 3.2-compatible: no wait -n, process-name kills, or external timeout tool.
stop_recording() {
  local was_alive=0 escalated=0 wait_status=0 attempts=0
  [[ -n "$RECORDER_PID" ]] || return 0
  if kill -0 "$RECORDER_PID" 2>/dev/null; then
    was_alive=1
    printf 'Stopping recorder PID %s with SIGINT.\n' "$RECORDER_PID" >> "$OUT/scan-motion-recording.log"
    kill -INT "$RECORDER_PID" 2>> "$OUT/scan-motion-recording.log" || escalated=1
    while kill -0 "$RECORDER_PID" 2>/dev/null && [[ "$attempts" -lt 50 ]]; do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if kill -0 "$RECORDER_PID" 2>/dev/null; then
      escalated=1
      echo 'Recorder did not finish after SIGINT; sending SIGTERM.' >> "$OUT/scan-motion-recording.log"
      kill -TERM "$RECORDER_PID" 2>> "$OUT/scan-motion-recording.log" || true
      attempts=0
      while kill -0 "$RECORDER_PID" 2>/dev/null && [[ "$attempts" -lt 10 ]]; do
        sleep 0.1
        attempts=$((attempts + 1))
      done
      if kill -0 "$RECORDER_PID" 2>/dev/null; then
        echo 'Recorder still running; sending SIGKILL (recording is failed).' >> "$OUT/scan-motion-recording.log"
        kill -KILL "$RECORDER_PID" 2>> "$OUT/scan-motion-recording.log" || true
      fi
    fi
  else
    echo 'Recorder exited before the requested stop; recording is failed.' >> "$OUT/scan-motion-recording.log"
  fi
  if wait "$RECORDER_PID"; then wait_status=0; else wait_status=$?; fi
  printf 'Recorder exit=%s; alive_before_stop=%s; escalated=%s\n' \
    "$wait_status" "$was_alive" "$escalated" >> "$OUT/scan-motion-recording.log"
  RECORDER_PID=""
  # Some simctl versions report the requested SIGINT as 130. It is accepted
  # only after our own orderly stop AND independent MP4 validation below.
  [[ "$was_alive" -eq 1 && "$escalated" -eq 0 && ( "$wait_status" -eq 0 || "$wait_status" -eq 130 ) ]]
}

finish() {
  local status=$?
  trap - EXIT
  # A second cancellation signal must not interrupt the bounded child cleanup.
  trap '' INT TERM
  set +e
  if [[ -n "$RECORDER_PID" ]]; then
    if ! stop_recording; then
      RECORDING_STATUS=failed
      if [[ "$status" -eq 0 ]]; then status=1; fi
    fi
  fi
  if [[ "$RECORDING_APP_LAUNCHED" -eq 1 && -n "$DEVICE" ]]; then
    xcrun simctl terminate "$DEVICE" com.ruyuan.aesthetics >> "$OUT/scan-motion-launch.log" 2>&1
  fi
  # set -e jumps here as soon as XCTest fails. Export diagnostics in the EXIT
  # handler, not after the test command, so failure screenshots are retained too.
  if [[ -d "$OUT/Test.xcresult" ]]; then
    if xcrun xcresulttool export attachments --path "$OUT/Test.xcresult" \
      --output-path "$OUT/TestAttachments" > "$OUT/attachment-export.log" 2>&1; then
      if ditto -c -k --sequesterRsrc --keepParent "$OUT/TestAttachments" \
        "$OUT/TestAttachments.zip" >> "$OUT/attachment-export.log" 2>&1; then
        ATTACHMENT_STATUS=passed
      else
        ATTACHMENT_STATUS=packaging_failed
        echo 'Attachment ZIP packaging failed; original Test.xcresult is retained.' >> "$OUT/attachment-export.log"
      fi
    else
      ATTACHMENT_STATUS=unavailable
      echo 'UI attachment export unavailable; original Test.xcresult is retained.' >> "$OUT/attachment-export.log"
    fi
  fi
  # Zip bundles to preserve their internal layout/permissions. Only these
  # explicitly named outputs are uploaded, never the checkout or private data.
  local bundle
  for bundle in Build Test; do
    if [[ -d "$OUT/$bundle.xcresult" ]]; then
      ditto -c -k --sequesterRsrc --keepParent "$OUT/$bundle.xcresult" \
        "$OUT/$bundle.xcresult.zip" >> "$OUT/packaging.log" 2>&1
      if [[ "$?" -ne 0 && "$status" -eq 0 ]]; then status=1; fi
    fi
  done
  if [[ "$BOOTED_BY_SCRIPT" -eq 1 && -n "$DEVICE" ]]; then
    xcrun simctl shutdown "$DEVICE" >> "$OUT/simulator-shutdown.log" 2>&1
  fi
  printf 'build=%s\ntests=%s\nattachment_export=%s\nsynthetic_scan_recording=%s\nexit_code=%s\n' \
    "$BUILD_STATUS" "$TEST_STATUS" "$ATTACHMENT_STATUS" "$RECORDING_STATUS" "$status" | tee "$OUT/status.txt"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## 如愿美学 · iOS 模拟器\n\n'
      printf -- '- Build: `%s`\n- XCTest: `%s`\n- Synthetic scan recording: `%s`\n- Exit code: `%s`\n' \
        "$BUILD_STATUS" "$TEST_STATUS" "$RECORDING_STATUS" "$status"
      printf '\n产物是模拟器 `.app`，不是 IPA，不能安装到 iPhone。\n'
      printf '请下载本次运行的 Artifacts 查看日志和已有的 `.xcresult.zip`。\n'
      printf '录屏仅使用内置合成 SampleData 自然播放，不含用户照片、相机或私人文件；实际结果见 `ScanMotion-Synthetic.mp4` 与录屏日志。\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This script requires macOS and a complete Xcode installation.' | tee "$OUT/setup.log"
  exit 1
fi
run_logged verify-segmentation-model python3 scripts/setup_segmentation_model.py --check
run_logged verify-face-landmarker-model python3 scripts/setup_face_landmarker_model.py --check
run_logged verify-pore-net-model python3 scripts/setup_pore_net_model.py --check
run_logged verify-acne-segmentation-model python3 scripts/setup_acne_segmentation_model.py --check
if [[ -f docs/models/coreml-artifacts.json ]]; then
  run_logged install-classifier-models python3 scripts/install_coreml_artifacts.py
  run_logged verify-classifier-models python3 scripts/install_coreml_artifacts.py --check
fi
run_logged generate-project python3 scripts/generate_xcode_project.py
run_logged environment bash -c 'set -e; uname -m; sw_vers; xcode-select -p; xcodebuild -version; xcrun --sdk iphonesimulator --show-sdk-version'
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
xcrun simctl list runtimes --json > "$OUT/runtimes.json"
xcrun simctl list devices available --json > "$OUT/devices.json"

# Never assume a particular iPhone name/UDID. Choose an installed available iOS
# runtime no newer than this Xcode's simulator SDK and not older than iOS 17.
run_logged select-simulator python3 - "$OUT/runtimes.json" "$OUT/devices.json" \
  "$SDK_VERSION" "$OUT/simulator.json" <<'PY'
import json
import re
import sys
from pathlib import Path

runtimes = json.loads(Path(sys.argv[1]).read_text())["runtimes"]
devices = json.loads(Path(sys.argv[2]).read_text())["devices"]

def version(value):
    parts = [int(x) for x in re.findall(r"\d+", value)[:3]]
    return tuple((parts + [0, 0, 0])[:3])

sdk = version(sys.argv[3])
candidates = []
for runtime in runtimes:
    if not runtime.get("isAvailable"):
        continue
    if ".iOS-" not in runtime["identifier"]:
        continue
    runtime_version = version(runtime["version"])
    if not (version("17.0") <= runtime_version <= sdk):
        continue
    for device in devices.get(runtime["identifier"], []):
        if not device.get("isAvailable", True) or not device["name"].startswith("iPhone"):
            continue
        candidates.append((runtime_version, device["state"] == "Booted", device["name"], {
            "udid": device["udid"], "name": device["name"], "state": device["state"],
            "runtime": runtime["identifier"], "runtime_version": runtime["version"],
            "simulator_sdk": sys.argv[3],
        }))
if not candidates:
    raise SystemExit("No installed available iPhone simulator for iOS 17 through SDK " + sys.argv[3]
                     + ". Select a compatible Xcode/runtime; no runtime will be downloaded automatically.")
selected = max(candidates, key=lambda item: item[:3])[3]
text = json.dumps(selected, ensure_ascii=False, indent=2)
Path(sys.argv[4]).write_text(text + "\n")
print(text)
PY

DEVICE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$OUT/simulator.json")"
DEVICE_STATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$OUT/simulator.json")"
ARGS=(-project "$ROOT/iOS/Ruyuan.xcodeproj" -scheme Ruyuan
  -configuration Debug -sdk iphonesimulator -derivedDataPath "$DERIVED"
  -destination "platform=iOS Simulator,id=$DEVICE,arch=arm64" -destination-timeout 120
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)

BUILD_STATUS=failed
run_logged build xcodebuild "${ARGS[@]}" -resultBundlePath "$OUT/Build.xcresult" build
BUILD_STATUS=passed

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Ruyuan.app"
[[ -d "$APP" ]] || { echo 'Build finished but Ruyuan.app is missing.'; exit 1; }
run_logged package-app ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Ruyuan-Simulator.app.zip"

# Package the compiled app before tests, so it remains available if XCTest fails.
if [[ "$DEVICE_STATE" != Booted ]]; then
  run_logged simulator-boot xcrun simctl boot "$DEVICE"
  BOOTED_BY_SCRIPT=1
fi
run_logged simulator-bootstatus xcrun simctl bootstatus "$DEVICE" -b
TEST_STATUS=failed
run_logged test xcodebuild "${ARGS[@]}" -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -resultBundlePath "$OUT/Test.xcresult" test
TEST_STATUS=passed

# This is additional visual evidence AFTER all existing XCTest passes, not a
# substitute for tests. Reinstall the same tested Debug app on the exact device:
# XCTest may use a cloned simulator. Only this bundle is terminated/relaunched.
# --ui-test-scan is the existing DEBUG-only, explicitly labelled synthetic
# SampleData fixture. No Photos import, camera, user file, or private face.
RECORDING_STATUS=failed
printf 'Source: bundled synthetic SampleData only\nDevice: %s\nCodec: h264\nTarget: 41-second recording, natural playback after launch\nUTC: %s\n' \
  "$DEVICE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/scan-motion-recording.log"
run_logged scan-motion-install xcrun simctl install "$DEVICE" "$APP"
if xcrun simctl terminate "$DEVICE" com.ruyuan.aesthetics > "$OUT/scan-motion-launch.log" 2>&1; then
  echo 'Previous Ruyuan instance terminated.' >> "$OUT/scan-motion-launch.log"
else
  echo 'No running Ruyuan instance to terminate; continuing with a fresh launch.' >> "$OUT/scan-motion-launch.log"
fi
xcrun simctl io "$DEVICE" recordVideo --codec=h264 "$OUT/ScanMotion-Synthetic.mp4" \
  >> "$OUT/scan-motion-recording.log" 2>&1 &
RECORDER_PID=$!

# Wait for the real recorder, not an invented success or a fixed startup delay.
# Either simctl's readiness message or a nonempty output proves writer startup;
# codec, complete atoms, duration and nonempty media are checked after SIGINT.
RECORDING_READY=0
for ((attempt=0; attempt<100; attempt++)); do
  if ! kill -0 "$RECORDER_PID" 2>/dev/null; then
    echo 'Recorder exited during startup.' >> "$OUT/scan-motion-recording.log"
    exit 1
  fi
  if grep -qi 'Recording started' "$OUT/scan-motion-recording.log" || [[ -s "$OUT/ScanMotion-Synthetic.mp4" ]]; then
    RECORDING_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$RECORDING_READY" -ne 1 ]]; then
  echo 'Recorder did not become ready within 10 seconds.' >> "$OUT/scan-motion-recording.log"
  exit 1
fi
RECORDING_STARTED_AT="$(python3 -c 'import time; print(time.monotonic())')"
RECORDING_APP_LAUNCHED=1
run_logged scan-motion-launch-synthetic xcrun simctl launch "$DEVICE" com.ruyuan.aesthetics --ui-test-scan
# Include launch time in the 41-second budget. Never pause, step, or fast-forward
# this run: the first six scenes and the real full-face -> brow ROI motion play.
run_logged scan-motion-duration python3 - "$RECORDING_STARTED_AT" <<'PY'
import sys
import time

elapsed = time.monotonic() - float(sys.argv[1])
if elapsed > 3:
    raise SystemExit(f"Synthetic launch took {elapsed:.3f}s; too much of the recording would precede the scan.")
time.sleep(max(0, 41 - elapsed))
print(f"Natural playback recording budget: {time.monotonic() - float(sys.argv[1]):.3f}s")
PY
stop_recording

# Validate the actual simctl output without downloading ffmpeg/ffprobe. Bounds
# checks reject truncated atom tables, and moov/mvhd + video sample metadata
# reject empty/unfinalized recordings. This never creates or replaces a video.
run_logged scan-motion-verify python3 - "$OUT/ScanMotion-Synthetic.mp4" "$OUT/scan-motion-video.json" <<'PY'
import hashlib
import json
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
size = path.stat().st_size
if size < 16384:
    raise SystemExit(f"Recording is absent or too small: {size} bytes")
with path.open("rb") as stream:
    def read(offset, count):
        stream.seek(offset)
        data = stream.read(count)
        if len(data) != count:
            raise ValueError("Truncated MP4 payload")
        return data

    def atoms(start, end):
        result = []
        while start < end:
            if end - start < 8:
                raise ValueError("Truncated MP4 atom header")
            length, kind = struct.unpack(">I4s", read(start, 8))
            header = 8
            if length == 1:
                length = struct.unpack(">Q", read(start + 8, 8))[0]
                header = 16
            elif length == 0:
                length = end - start
            if length < header or start + length > end:
                raise ValueError(f"Invalid {kind!r} atom length {length}")
            result.append((kind, start + header, start + length))
            start += length
        return result

    def child(parent, name):
        matches = [atom for atom in atoms(parent[1], parent[2]) if atom[0] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected one {name!r} atom, got {len(matches)}")
        return matches[0]

    def payload(atom, offset, count):
        if offset < 0 or atom[1] + offset + count > atom[2]:
            raise ValueError(f"Truncated {atom[0]!r} payload")
        return read(atom[1] + offset, count)

    top = atoms(0, size)
    movie = child((b"root", 0, size), b"moov")
    if not any(atom[0] == b"ftyp" for atom in top):
        raise ValueError("Missing MP4 file type")
    media_bytes = sum(end - start for kind, start, end in top if kind == b"mdat")
    if media_bytes <= 0:
        raise ValueError("Missing recorded media payload")
    header = child(movie, b"mvhd")
    version = payload(header, 0, 1)[0]
    if version == 0:
        timescale, ticks = struct.unpack(">II", payload(header, 12, 8))
    elif version == 1:
        timescale = struct.unpack(">I", payload(header, 20, 4))[0]
        ticks = struct.unpack(">Q", payload(header, 24, 8))[0]
    else:
        raise ValueError(f"Unsupported movie header version {version}")
    duration = ticks / timescale if timescale else 0
    if not 40 <= duration <= 44:
        raise ValueError(f"Expected approximately 41 seconds; actual MP4 duration is {duration:.3f}s")
    video_tracks = []
    for track in [atom for atom in atoms(movie[1], movie[2]) if atom[0] == b"trak"]:
        media = child(track, b"mdia")
        handler = child(media, b"hdlr")
        if payload(handler, 8, 4) != b"vide":
            continue
        samples = child(child(media, b"minf"), b"stbl")
        description = child(samples, b"stsd")
        if struct.unpack(">I", payload(description, 4, 4))[0] < 1:
            raise ValueError("Missing video sample description")
        entry_size = struct.unpack(">I", payload(description, 8, 4))[0]
        if entry_size < 8 or 8 + entry_size > description[2] - description[1]:
            raise ValueError("Truncated video sample description")
        codec = payload(description, 12, 4).decode("ascii")
        if codec not in ("avc1", "avc3"):
            raise ValueError(f"Expected H.264; actual codec is {codec}")
        sample_sizes = child(samples, b"stsz")
        fixed_size, sample_count = struct.unpack(">II", payload(sample_sizes, 4, 8))
        if sample_count < 2:
            raise ValueError("Recording has fewer than two video samples")
        if fixed_size == 0 and 12 + sample_count * 4 > sample_sizes[2] - sample_sizes[1]:
            raise ValueError("Truncated video sample size table")
        video_tracks.append({"codec": codec, "sample_count": sample_count})
    if not video_tracks:
        raise ValueError("No recorded H.264 video track")

digest = hashlib.sha256()
with path.open("rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
metadata = {
    "file": path.name, "source": "bundled synthetic SampleData; --ui-test-scan",
    "duration_seconds": duration, "size_bytes": size, "media_bytes": media_bytes,
    "video_tracks": video_tracks, "sha256": digest.hexdigest(),
    "scope": "natural simulator playback only; not a real-person/device analysis",
}
text = json.dumps(metadata, ensure_ascii=False, indent=2)
Path(sys.argv[2]).write_text(text + "\n", encoding="utf-8")
print(text)
PY
RECORDING_STATUS=passed
