#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo '请安装完整 Xcode，打开一次并完成许可/组件安装，然后在 Xcode Settings > Locations 选择 Command Line Tools。'
  exit 1
fi
ARGS=(-project "$ROOT/iOS/Ruyuan.xcodeproj" -scheme Ruyuan -derivedDataPath "$ROOT/.build" CODE_SIGNING_ALLOWED=NO)
if [[ "${1:-}" == "--test" ]]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for a in d["devices"].values() for x in a if "iPhone" in x["name"]), ""))')"
  [[ -n "$DEVICE" ]] || { echo '请先在 Xcode 安装 iOS Simulator runtime。'; exit 1; }
  xcodebuild "${ARGS[@]}" -destination "platform=iOS Simulator,id=$DEVICE" -resultBundlePath "$ROOT/.build/Test-$(date +%Y%m%d-%H%M%S).xcresult" test
else
  xcodebuild "${ARGS[@]}" -destination 'generic/platform=iOS Simulator' build
fi
