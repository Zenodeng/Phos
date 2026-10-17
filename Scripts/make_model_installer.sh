#!/bin/sh
# 打「可选模型安装包」——只含脚本与依赖/哈希清单，不含 3.1GB 底模，也不含任何照片。
#
# 用法：
#   ./Scripts/make_model_installer.sh            # 产出 ./Phos-Optional-Model-Installer.zip
#   ./Scripts/make_model_installer.sh <输出路径>
#
# 包内结构固定为 Phos-Optional-Model/…，用户解压后双击「安装模型.command」即可。
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

SRC="Tools/OptionalModel"
OUT="${1:-Phos-Optional-Model-Installer.zip}"

[ -d "$SRC" ] || { echo "缺少 $SRC" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phos-model-installer.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/Phos-Optional-Model"
for FILE in README.md install_model.py model-manifest.json requirements.lock.txt "安装模型.command"; do
    [ -f "$SRC/$FILE" ] || { echo "缺少 $SRC/$FILE" >&2; exit 1; }
    cp "$SRC/$FILE" "$STAGE/Phos-Optional-Model/$FILE"
done
chmod +x "$STAGE/Phos-Optional-Model/安装模型.command"

# 输出路径转成绝对路径，才能在暂存目录里打包
case "$OUT" in
    /*) OUT_ABS="$OUT" ;;
    *)  OUT_ABS="$PWD/$OUT" ;;
esac
rm -f "$OUT_ABS"

# 用 Python 的 zipfile 而不是 zip(1)：
# macOS 自带的 zip 会把中文文件名按原始 UTF-8 字节写进去，却不置 0x0800 标记，
# 别的解压工具（Windows、部分 GUI）会按 cp437 解码成乱码。zipfile 会自动置标记。
python3 - "$STAGE" "$OUT_ABS" <<'PY'
import os
import sys
import zipfile

stage, out = sys.argv[1], sys.argv[2]
root = os.path.join(stage, "Phos-Optional-Model")
names = sorted(os.listdir(root))
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in names:
        archive.write(os.path.join(root, name), arcname="Phos-Optional-Model/" + name)
print("  写入 %d 个文件" % len(names))
PY

[ -s "$OUT_ABS" ] || { echo "打包失败：没有产出 $OUT_ABS" >&2; exit 1; }
echo "已生成 ${OUT_ABS}（$(du -h "$OUT_ABS" | cut -f1)）"
