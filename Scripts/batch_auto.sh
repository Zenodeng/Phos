#!/bin/bash
# 批量「一键自动」：对一整个文件夹的照片跑和界面里「自动」按钮一样的计算，
# 结果写进各自的 .rawforge.json 伴生文件，之后在 Phos 里打开该文件夹即可看到。
#
# 只编译引擎相关文件，绕开 Inspector.swift 的类型检查瓶颈（同 test_autotone.sh）。
#
# 用法：
#   bash Scripts/batch_auto.sh plan  <图片或目录...>             只算不写，先看会怎么改
#   bash Scripts/batch_auto.sh apply <图片或目录...>             计算并写入
#   bash Scripts/batch_auto.sh apply --unify <目录>              整批统一题材
#   bash Scripts/batch_auto.sh apply --scene landscape <目录>    强制指定题材
#   bash Scripts/batch_auto.sh apply --dry <目录>                只打印不落盘
#   bash Scripts/batch_auto.sh apply --force <目录>              覆盖已有调整（慎用）
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${RF_SDK:-}"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
    SDK="$(xcrun --show-sdk-path)"
fi

OUT="build/batchauto"
mkdir -p "$OUT"

SRC="Sources/Phos/Engine.swift Sources/Phos/Models.swift Sources/Phos/CLUT.swift \
Sources/Phos/Performance.swift Sources/Phos/Alignment.swift Sources/Phos/Workflow.swift \
Sources/Phos/AutoTone.swift Sources/Phos/SceneClassifier.swift Tools/BatchAuto.swift"

# 源码没变就沿用上次的二进制，省掉每次约 20 秒的编译。
needs_build=1
if [[ -x "$OUT/batchauto" ]]; then
    needs_build=0
    for f in $SRC; do
        if [[ "$f" -nt "$OUT/batchauto" ]]; then needs_build=1; break; fi
    done
fi

if [[ $needs_build -eq 1 ]]; then
    echo "编译中…"
    swiftc -O -suppress-warnings -D PHOS_TESTING -sdk "$SDK" \
        -target arm64-apple-macosx15.0 -module-cache-path "$OUT/cache" \
        $SRC -o "$OUT/batchauto"
fi

"$OUT/batchauto" "$@"
