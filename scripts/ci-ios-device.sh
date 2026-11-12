#!/bin/bash
# Real iphoneos Release binary, not a simulator app renamed to IPA.
# No signing credentials, network SDK installs, model downloads or user photos.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${CI_ARTIFACTS_DIR:-$ROOT/.build/iphone-ci/$(date +%Y%m%d-%H%M%S)-$$}"
if [[ -e "$OUT" && ! -d "$OUT" ]] || \
   [[ -d "$OUT" && -n "$(ls -A "$OUT")" ]]; then
  echo 'Use a fresh empty CI_ARTIFACTS_DIR; refusing to reuse old artifacts.'
  exit 1
fi
mkdir -p "$OUT"
DERIVED="$OUT/DerivedData"
BUILD_STATUS=not_run
VERIFY_STATUS=not_run
PACKAGE_STATUS=not_run

run_logged() {
  local name="$1"
  shift
  local statuses
  set +e
  "$@" 2>&1 | tee "$OUT/$name.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "${statuses[0]}" -ne 0 ]]; then return "${statuses[0]}"; fi
  return "${statuses[1]}"
}

finish() {
  local status=$?
  trap - EXIT
  set +e
  if [[ -d "$OUT/Build.xcresult" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$OUT/Build.xcresult" \
      "$OUT/Build.xcresult.zip" >> "$OUT/result-packaging.log" 2>&1
    if [[ "$?" -ne 0 && "$status" -eq 0 ]]; then status=1; fi
  fi
  # Do not leave an incomplete IPA in failure artifacts.
  if [[ "$PACKAGE_STATUS" != passed && -f "$OUT/Ruyuan-iPhone-Unsigned.ipa" ]]; then
    rm -f "$OUT/Ruyuan-iPhone-Unsigned.ipa"
  fi
  printf 'build=%s\niphone_binary_verification=%s\nipa_packaging=%s\nexit_code=%s\n' \
    "$BUILD_STATUS" "$VERIFY_STATUS" "$PACKAGE_STATUS" "$status" | tee "$OUT/status.txt"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## 如愿美学 · iPhone 真机未签名 IPA\n\n'
      printf -- '- Release iphoneos build: `%s`\n- arm64 / IOS verification: `%s`\n- IPA: `%s`\n- Exit code: `%s`\n' \
        "$BUILD_STATUS" "$VERIFY_STATUS" "$PACKAGE_STATUS" "$status"
      printf '\n这是未签名真机 IPA，不能直接点击安装；需在你自己的电脑用自己的 Apple ID 签名后安装。\n'
      printf '不含证书、描述文件或 Apple ID 凭据；本流程没有执行真机安装、相机测试或 XCTest。\n'
      if [[ "$status" -ne 0 ]]; then
        printf '\n构建未完成：请查看 Artifacts 中 status.txt、build.log 及已有的 Build.xcresult.zip。\n'
      fi
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
run_logged environment bash -c 'set -e; sw_vers; xcode-select -p; xcodebuild -version; xcrun --sdk iphoneos --show-sdk-version'

BUILD_STATUS=failed
run_logged build xcodebuild -project "$ROOT/iOS/Ruyuan.xcodeproj" -scheme Ruyuan \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/Build.xcresult" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build
BUILD_STATUS=passed

APP="$DERIVED/Build/Products/Release-iphoneos/Ruyuan.app"
[[ -d "$APP" ]] || { echo 'Release-iphoneos/Ruyuan.app is missing.'; exit 1; }
VERIFY_STATUS=failed
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
EXECUTABLE="$APP/$EXECUTABLE_NAME"
[[ -f "$EXECUTABLE" ]] || { echo 'App executable is missing.'; exit 1; }
run_logged binary-architecture xcrun lipo -archs "$EXECUTABLE"
[[ "$(cat "$OUT/binary-architecture.log")" == arm64 ]] || \
  { echo 'Expected only arm64 device architecture.'; exit 1; }
run_logged binary-platform xcrun vtool -show-build "$EXECUTABLE"
grep -Eq '^[[:space:]]*platform[[:space:]]+IOS[[:space:]]*$' "$OUT/binary-platform.log" || \
  { echo 'Mach-O is not an iOS device binary.'; exit 1; }
if grep -q 'IOSSIMULATOR' "$OUT/binary-platform.log"; then
  echo 'Simulator binary rejected.'
  exit 1
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms' "$APP/Info.plist" \
  | tee "$OUT/supported-platforms.log"
grep -q 'iPhoneOS' "$OUT/supported-platforms.log" || \
  { echo 'Info.plist does not declare iPhoneOS.'; exit 1; }
VERIFY_STATUS=passed

PACKAGE_STATUS=failed
mkdir -p "$OUT/package/Payload"
run_logged stage-app ditto "$APP" "$OUT/package/Payload/Ruyuan.app"
run_logged package-ipa ditto -c -k --sequesterRsrc --keepParent \
  "$OUT/package/Payload" "$OUT/Ruyuan-iPhone-Unsigned.ipa"
run_logged verify-zip unzip -t "$OUT/Ruyuan-iPhone-Unsigned.ipa"
unzip -Z -1 "$OUT/Ruyuan-iPhone-Unsigned.ipa" > "$OUT/ipa-contents.txt"
grep -Fxq "Payload/Ruyuan.app/$EXECUTABLE_NAME" "$OUT/ipa-contents.txt" || \
  { echo 'IPA is missing Payload/Ruyuan.app executable.'; exit 1; }
run_logged checksum shasum -a 256 "$OUT/Ruyuan-iPhone-Unsigned.ipa"
PACKAGE_STATUS=passed
