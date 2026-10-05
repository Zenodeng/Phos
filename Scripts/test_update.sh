#!/bin/bash
# 版本比较回归：纯逻辑，不联网、不需要照片素材，秒级跑完。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/phos-update.XXXXXX")"
swiftc -O -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -module-cache-path "$OUT/module-cache" \
    Sources/Phos/Update.swift Tools/UpdateTest.swift -o "$OUT/test"

"$OUT/test"
