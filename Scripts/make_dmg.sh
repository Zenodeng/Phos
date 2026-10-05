#!/bin/bash
# 把 Phos.app 打成 DMG —— 带背景图、拖到「应用程序」的引导、以及「首次打开必读.txt」。
#
#   ./Scripts/make_dmg.sh [Phos.app 路径] [输出 .dmg 路径]
#
# 默认取仓库根目录的 Phos.app（Scripts/package_app.sh 的产物），
# 输出到仓库根目录的 Phos-macOS-apple-silicon.dmg。
#
# 布局用 dmgbuild 生成 .DS_Store，**不依赖 Finder AppleScript** ——
# 后者需要图形会话和「自动化」权限，在 CI 与无头环境下不可靠。
#   pip install dmgbuild
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-$PWD/Phos.app}"
OUT="${2:-$PWD/Phos-macOS-apple-silicon.dmg}"
ASSETS="$PWD/Scripts/dmg"
VOLNAME="Phos"

[ -d "$APP" ] || { echo "找不到 $APP —— 先跑 ./Scripts/package_app.sh" >&2; exit 1; }
[ -f "$ASSETS/background.png" ] || { echo "找不到背景图 $ASSETS/background.png" >&2; exit 1; }

# 1) 暂存目录：DMG 里最终会出现的东西
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phos-dmg.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/phos-dmgwork.XXXXXX")"
trap 'rm -rf "$STAGE" "$WORK"' EXIT
ditto "$APP" "$STAGE/Phos.app"
cp "$ASSETS/首次打开必读.txt" "$STAGE/"

# 2) 把 1x / 2x 两张 PNG 合成多分辨率 TIFF。
#    Finder 读 DMG 背景时会按屏幕挑合适的那一档，Retina 上才不会发虚。
#    -cathidpicheck 会校验两张图是不是合法的 HiDPI 配对（点数相同、像素 2 倍），
#    所以 background@2x.png 必须标 144dpi —— 由 Tools/DMGBackground.swift 负责。
BACKGROUND="$WORK/background.tiff"
tiffutil -cathidpicheck "$ASSETS/background.png" "$ASSETS/background@2x.png" \
    -out "$BACKGROUND" >/dev/null

rm -f "$OUT"

# 3) 找 dmgbuild（PATH 上，或本机隔离 venv 里）
DMGBUILD="$(command -v dmgbuild || true)"
if [ -z "$DMGBUILD" ] && [ -x "$HOME/.workbuddy-ai/binaries/python/envs/default/bin/dmgbuild" ]; then
    DMGBUILD="$HOME/.workbuddy-ai/binaries/python/envs/default/bin/dmgbuild"
fi

if [ -n "$DMGBUILD" ]; then
    DMG_STAGE="$STAGE" DMG_ASSETS="$ASSETS" DMG_BACKGROUND="$BACKGROUND" \
        "$DMGBUILD" -s "$ASSETS/settings.py" "$VOLNAME" "$OUT"
else
    echo "⚠️  没装 dmgbuild，退回无背景的普通 DMG（能装，只是不好看）" >&2
    echo "    想要带引导界面：pip install dmgbuild" >&2
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
fi

# 3) 自检
# 注意：全角括号紧跟变量时 bash 会把它算进变量名，所以这里一律写 ${OUT}
[ -f "$OUT" ] || { echo "打包失败：没有产出 ${OUT}" >&2; exit 1; }
echo "已生成 ${OUT} （$(du -h "${OUT}" | cut -f1)）"
