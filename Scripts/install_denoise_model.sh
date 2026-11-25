#!/bin/bash
set -euo pipefail

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
URL="${HF_ENDPOINT%/}/markhamilton/scunet-coreml/resolve/main/SCUNet.mlpackage.zip"
SHA_ZIP="f60c1b9e2e1e52a08876f7e6acb4848c52373d564531a30c12573b4e73ff24bf"
DEST_ROOT="$HOME/Library/Application Support/Phos/Models"
DEST_MODEL="$DEST_ROOT/Denoise.mlmodelc"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phos-denoise-install.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/unzip" "$TMP_DIR/compiled" "$DEST_ROOT"
ZIP_PATH="$TMP_DIR/SCUNet.mlpackage.zip"

echo "下载: $URL"
curl -fL --retry 3 --retry-delay 2 --progress-bar "$URL" -o "$ZIP_PATH"
ACTUAL_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$SHA_ZIP" ]]; then
    echo "SHA-256 校验失败: $ZIP_PATH" >&2
    echo "  期望: $SHA_ZIP" >&2
    echo "  实际: $ACTUAL_SHA" >&2
    exit 1
fi
echo "  SHA-256 校验通过: $ACTUAL_SHA"

unzip -q "$ZIP_PATH" -d "$TMP_DIR/unzip"
PKG_DIR="$(find "$TMP_DIR/unzip" -maxdepth 3 -name "*.mlpackage" ! -path "*__MACOSX*" ! -name "._*" | head -n 1)"
if [[ -z "$PKG_DIR" || ! -d "$PKG_DIR" ]]; then
    echo "解压后未找到 .mlpackage" >&2
    exit 1
fi

echo "正在使用 coremlcompiler 编译 SCUNet 降噪模型 ..."
xcrun coremlcompiler compile "$PKG_DIR" "$TMP_DIR/compiled"

COMPILED_CANDIDATE="$(find "$TMP_DIR/compiled" -maxdepth 2 -name "*.mlmodelc" | head -n 1)"
if [[ -z "$COMPILED_CANDIDATE" || ! -d "$COMPILED_CANDIDATE" ]]; then
    echo "编译输出缺失" >&2
    exit 1
fi

STAGE_DEST="$DEST_ROOT/.Denoise.mlmodelc.staging.$$"
rm -rf "$STAGE_DEST"
cp -R "$COMPILED_CANDIDATE" "$STAGE_DEST"

BACKUP_OLD="$DEST_ROOT/.Denoise.mlmodelc.old.$$"
rm -rf "$BACKUP_OLD"
if [[ -e "$DEST_MODEL" ]]; then
    mv "$DEST_MODEL" "$BACKUP_OLD"
fi
mv "$STAGE_DEST" "$DEST_MODEL"
rm -rf "$BACKUP_OLD"

echo "已安装 SCUNet AI 降噪模型到: $DEST_MODEL"
echo "磁盘占用: $(du -sh "$DEST_MODEL" | awk '{print $1}')"
