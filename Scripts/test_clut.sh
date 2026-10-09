#!/bin/bash
# .cube 3D LUT 原生支持的回归测试。
#
# 不走 -D PHOS_TESTING 的全量编译 —— 那条路会卡在 Inspector.swift 的类型检查
# （unable to type-check this expression in reasonable time），所以只编译引擎相关文件。
#
# 用法：
#   bash Scripts/test_clut.sh                  自检（合成 LUT，秒级）
#   bash Scripts/test_clut.sh list <目录>      扫一个真实 CLUT 目录，打印收录结果
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${RF_SDK:-}"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
    SDK="$(xcrun --show-sdk-path)"
fi

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/phos-clut.XXXXXX")"
swiftc -O -suppress-warnings -D PHOS_TESTING -sdk "$SDK" \
    -target arm64-apple-macosx15.0 -module-cache-path "$BUILD/cache" \
    Sources/Phos/Engine.swift \
    Sources/Phos/Models.swift \
    Sources/Phos/CLUT.swift \
    Sources/Phos/Performance.swift \
    Sources/Phos/Alignment.swift \
    Sources/Phos/Workflow.swift \
    Sources/Phos/AutoTone.swift \
    Sources/Phos/SceneClassifier.swift \
    Tools/CLUTTest.swift -o "$BUILD/cluttest"

"$BUILD/cluttest" "$@"
