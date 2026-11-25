#!/bin/bash
set -euo pipefail

VARIANT="512"
if [[ "${1:-}" == "--1024" ]]; then
    VARIANT="1024"
elif [[ "${1:-}" == "--512" || -z "${1:-}" ]]; then
    VARIANT="512"
else
    echo "用法: $0 [--512 | --1024]" >&2
    exit 2
fi

HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
REPO_BASE="${HF_ENDPOINT%/}/heypatkay/solume-big-lama-coreml/resolve/main"
DEST_ROOT="$HOME/Library/Application Support/Phos/Models"
DEST_MODEL="$DEST_ROOT/LaMa.mlmodelc"
DEST_LICENSE="$DEST_ROOT/LaMa-LICENSE.txt"

if [[ "$VARIANT" == "512" ]]; then
    SRC_PKG="lama/LaMa512.mlpackage"
    SHA_MANIFEST="a2576a37183e5a04265456092e18271e165564bd2e6578f6091e404236f3069b"
    SHA_MODEL="a50e4ed35d3588892615046a111d274451ee83d29e854175fc91acc1361ffdd1"
    SHA_WEIGHTS="4db509018e12aec710ab28d8ac1a88812665decf7511e538666590db3e5c88fb"
else
    SRC_PKG="lama/LaMa1024.mlpackage"
    SHA_MANIFEST="a2576a37183e5a04265456092e18271e165564bd2e6578f6091e404236f3069b"
    SHA_MODEL="6a9982664169088e86f419a0f7386befb83b05f86da357eb8ae1614fab4c7de3"
    SHA_WEIGHTS="90a84b283b4de10201c299413c530b5874c38e66cdc884254b0a7eea4bd17938"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phos-lama-install.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PKG_DIR="$TMP_DIR/LaMa.mlpackage"
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

download_and_verify "$REPO_BASE/LICENSE" "$TMP_DIR/LICENSE" ""
download_and_verify "$REPO_BASE/$SRC_PKG/Manifest.json" "$PKG_DIR/Manifest.json" "$SHA_MANIFEST"
download_and_verify "$REPO_BASE/$SRC_PKG/Data/com.apple.CoreML/model.mlmodel" "$PKG_DIR/Data/com.apple.CoreML/model.mlmodel" "$SHA_MODEL"
download_and_verify "$REPO_BASE/$SRC_PKG/Data/com.apple.CoreML/weights/weight.bin" "$PKG_DIR/Data/com.apple.CoreML/weights/weight.bin" "$SHA_WEIGHTS"

echo "正在使用 coremlcompiler 编译 LaMa${VARIANT}.mlpackage ..."
xcrun coremlcompiler compile "$PKG_DIR" "$OUT_DIR"

COMPILED_CANDIDATE="$OUT_DIR/LaMa.mlmodelc"
if [[ ! -d "$COMPILED_CANDIDATE" ]]; then
    echo "编译输出缺失: $COMPILED_CANDIDATE" >&2
    exit 1
fi

STAGE_DEST="$DEST_ROOT/.LaMa.mlmodelc.staging.$$"
rm -rf "$STAGE_DEST"
cp -R "$COMPILED_CANDIDATE" "$STAGE_DEST"

BACKUP_OLD="$DEST_ROOT/.LaMa.mlmodelc.old.$$"
rm -rf "$BACKUP_OLD"
if [[ -e "$DEST_MODEL" ]]; then
    mv "$DEST_MODEL" "$BACKUP_OLD"
fi
mv "$STAGE_DEST" "$DEST_MODEL"
rm -rf "$BACKUP_OLD"
cp "$TMP_DIR/LICENSE" "$DEST_LICENSE"

echo "已安装 LaMa${VARIANT} 模型到: $DEST_MODEL"
echo "磁盘占用: $(du -sh "$DEST_MODEL" | awk '{print $1}')"
