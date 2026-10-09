#!/bin/bash
# 自动影调（AutoTone）的回归测试。
#
# 不走 -D PHOS_TESTING 的全量编译 —— 那条路会卡在 Inspector.swift 的类型检查
# （unable to type-check this expression in reasonable time），所以只编译引擎相关文件。
#
# 用法：
#   bash Scripts/test_autotone.sh                     合成图自检（有已知答案，秒级）
#   bash Scripts/test_autotone.sh analyze <出图目录> <图片...>   输出参数 + 前后对比图
#   bash Scripts/test_autotone.sh sweep <目录>         批量统计参数分布，专找离谱值
#   bash Scripts/test_autotone.sh isolate <图片>       逐参数量引擎真实响应（调参用）
#   bash Scripts/test_autotone.sh scene <图片...>      只看场景识别结果（标定关键词表用）
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${RF_SDK:-}"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
    SDK="$(xcrun --show-sdk-path)"
fi

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/phos-autotone.XXXXXX")"
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
    Tools/AutoToneTest.swift -o "$BUILD/autotone"

MODE="${1:-synthetic}"
shift || true
"$BUILD/autotone" "$MODE" "$@"
