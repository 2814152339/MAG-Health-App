#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
open "$ROOT/iOS/Ruyuan.xcodeproj"
echo '已打开原生 iOS 工程。在 Xcode 选择 iPhone 模拟器，按 Command+R 运行。真机运行请在 Signing & Capabilities 选择自己的 Team。'
