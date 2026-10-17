#!/bin/bash
# 自动流水线：筛掉没对上焦的 → 按主体取向裁成 3:2 / 2:3 → 统一色调与曝光 → 导出 JPEG。
#
# 只编译引擎相关文件，绕开 Inspector.swift 的类型检查瓶颈（同 test_autotone.sh）。
#
# 用法：
#   bash Scripts/auto_finish.sh focus <目录>                      先看清晰度分布和建议阈值
#   bash Scripts/auto_finish.sh run --out <导出目录> <目录>         完整流水线
#   bash Scripts/auto_finish.sh run --out <目录> --dry --limit 8 <目录>   小批量试跑，不落盘
#
# 常用选项：
#   --no-cull              不再筛脱焦（照片已经人工/AI 选过时用）
#   --style sports         叠加「运动系」风格层（叠在自动影调之上）
#   --style-strength 1.2   风格强度，默认 1
#   --crop none            不裁切，保留原画幅
#   --min-retain 0.5       裁切后至少保留原图 50% 面积（默认 0.40）
#   --focus-ratio 0.45     低于「全批清晰度中位 × 该比例」判为脱焦（默认 0.45）
#   --wb-unify 0.6         白平衡向全批中位数靠拢 60%（默认），1=完全统一
#   --scene portrait       影调题材（默认 portrait）
#   --long-edge 3000       导出长边，0=原始尺寸
#   --dry                  只打印不落盘
#
# 风格标定（先跑这个看数字再定强度）：
#   bash Scripts/auto_finish.sh sweep --style-strength 1 <任意一张图>
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${RF_SDK:-}"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
    SDK="$(xcrun --show-sdk-path)"
fi

OUT="build/autofinish"
mkdir -p "$OUT"

SRC="Sources/Phos/Engine.swift Sources/Phos/Models.swift Sources/Phos/CLUT.swift \
Sources/Phos/Performance.swift Sources/Phos/Alignment.swift Sources/Phos/Workflow.swift \
Sources/Phos/AutoTone.swift Sources/Phos/SceneClassifier.swift Tools/AutoFinish.swift"

needs_build=1
if [[ -x "$OUT/autofinish" ]]; then
    needs_build=0
    for f in $SRC; do
        if [[ "$f" -nt "$OUT/autofinish" ]]; then needs_build=1; break; fi
    done
fi

if [[ $needs_build -eq 1 ]]; then
    echo "编译中…"
    swiftc -O -suppress-warnings -D PHOS_TESTING -sdk "$SDK" \
        -target arm64-apple-macosx15.0 -module-cache-path "$OUT/cache" \
        $SRC -o "$OUT/autofinish"
fi

"$OUT/autofinish" "$@"
