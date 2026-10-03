#!/bin/bash
# 蒙版控制点拖动回归：纯几何计算，不需要照片素材，也不需要图形服务。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/phos-mask-drag.XXXXXX")"
swiftc -O -D PHOS_TESTING -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -module-cache-path "$OUT/module-cache" \
    Sources/Phos/Models.swift Sources/Phos/Workflow.swift Sources/Phos/Engine.swift \
    Sources/Phos/CLUT.swift Sources/Phos/Performance.swift Sources/Phos/Alignment.swift \
    Tools/MaskDragTest.swift -o "$OUT/test"

"$OUT/test"
