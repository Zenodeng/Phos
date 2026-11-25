#!/bin/bash
set -euo pipefail

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
REPO_BASE="${HF_ENDPOINT%/}/melmass/skyseg-coreml/resolve/main"
SRC_PKG="SkySegmentation.mlpackage"
DEST_ROOT="$HOME/Library/Application Support/Phos/Models"
DEST_MODEL="$DEST_ROOT/SkySegmentation.mlmodelc"

SHA_MANIFEST="5e052e2066110f56df5ba9bad1994bd70a29f9ba8e5f5be9139dd37092a1e6a0"
SHA_MODEL="e7bdf3db8311bcbf234cb5f8588ca35eb56960ceb74b3800f992d548df23e459"
SHA_WEIGHTS="432cc9d7de9c19b9c9ba8309af3f120cfa9df5d273263a6269233cc61f60c869"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phos-sky-install.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PKG_DIR="$TMP_DIR/SkySegmentation.mlpackage"
OUT_DIR="$TMP_DIR/compiled"
mkdir -p "$PKG_DIR/Data/com.apple.CoreML/weights" "$OUT_DIR" "$DEST_ROOT"

download_and_verify() {
    local url="$1"
    local dest="$2"
    local expected_sha="$3"
    echo "下载: $url"
    curl -fL --retry 3 --retry-delay 2 --progress-bar "$url" -o "$dest"
    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            echo "SHA-256 校验失败: $dest" >&2
            echo "  期望: $expected_sha" >&2
            echo "  实际: $actual_sha" >&2
            exit 1
        fi
        echo "  SHA-256 校验通过: $actual_sha"
    fi
}

download_and_verify "$REPO_BASE/$SRC_PKG/Manifest.json" "$PKG_DIR/Manifest.json" "$SHA_MANIFEST"
download_and_verify "$REPO_BASE/$SRC_PKG/Data/com.apple.CoreML/model.mlmodel" "$PKG_DIR/Data/com.apple.CoreML/model.mlmodel" "$SHA_MODEL"
download_and_verify "$REPO_BASE/$SRC_PKG/Data/com.apple.CoreML/weights/weight.bin" "$PKG_DIR/Data/com.apple.CoreML/weights/weight.bin" "$SHA_WEIGHTS"

echo "正在使用 coremlcompiler 编译 SkySegmentation.mlpackage ..."
xcrun coremlcompiler compile "$PKG_DIR" "$OUT_DIR"

COMPILED_CANDIDATE="$OUT_DIR/SkySegmentation.mlmodelc"
if [[ ! -d "$COMPILED_CANDIDATE" ]]; then
    echo "编译输出缺失: $COMPILED_CANDIDATE" >&2
    exit 1
fi

STAGE_DEST="$DEST_ROOT/.SkySegmentation.mlmodelc.staging.$$"
rm -rf "$STAGE_DEST"
cp -R "$COMPILED_CANDIDATE" "$STAGE_DEST"

BACKUP_OLD="$DEST_ROOT/.SkySegmentation.mlmodelc.old.$$"
rm -rf "$BACKUP_OLD"
if [[ -e "$DEST_MODEL" ]]; then
    mv "$DEST_MODEL" "$BACKUP_OLD"
fi
mv "$STAGE_DEST" "$DEST_MODEL"
rm -rf "$BACKUP_OLD"

echo "已安装 SkySegmentation 模型到: $DEST_MODEL"
echo "磁盘占用: $(du -sh "$DEST_MODEL" | awk '{print $1}')"
