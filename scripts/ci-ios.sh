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

finish() {
  local status=$?
  trap - EXIT
  set +e
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
  printf 'build=%s\ntests=%s\nattachment_export=%s\nexit_code=%s\n' \
    "$BUILD_STATUS" "$TEST_STATUS" "$ATTACHMENT_STATUS" "$status" | tee "$OUT/status.txt"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## 如愿美学 · iOS 模拟器\n\n'
      printf -- '- Build: `%s`\n- XCTest: `%s`\n- Exit code: `%s`\n' \
        "$BUILD_STATUS" "$TEST_STATUS" "$status"
      printf '\n产物是模拟器 `.app`，不是 IPA，不能安装到 iPhone。\n'
      printf '请下载本次运行的 Artifacts 查看日志和已有的 `.xcresult.zip`。\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit "$status"
}
trap finish EXIT

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This script requires macOS and a complete Xcode installation.' | tee "$OUT/setup.log"
  exit 1
fi
run_logged verify-segmentation-model python3 scripts/setup_segmentation_model.py --check
run_logged verify-face-landmarker-model python3 scripts/setup_face_landmarker_model.py --check
run_logged verify-pore-net-model python3 scripts/setup_pore_net_model.py --check
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
