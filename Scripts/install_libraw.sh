#!/usr/bin/env bash
# 一键安装可选 LibRaw 动态库至 ~/Library/Application Support/Phos/LibRaw/libraw.dylib
# 零 App 体积膨胀：优先复用 Homebrew libraw；无 Homebrew 时直接用 Xcode Command Line Tools 编译官方 LibRaw 源码。
set -euo pipefail

DEST_DIR="$HOME/Library/Application Support/Phos/LibRaw"
DEST_LIB="$DEST_DIR/libraw.dylib"
LIBRAW_VER="${LIBRAW_VER:-0.21.4}"
mkdir -p "$DEST_DIR"

echo "==> [Phos] 安装可选 LibRaw 运行时（目标：${DEST_LIB}）"

if command -v brew >/dev/null 2>&1; then
    echo "检测到 Homebrew，安装/定位 libraw…"
    brew list libraw >/dev/null 2>&1 || brew install libraw
    BREW_PREFIX="$(brew --prefix libraw)"
    if [ -f "$BREW_PREFIX/lib/libraw.dylib" ]; then
        cp -L "$BREW_PREFIX/lib/libraw.dylib" "$DEST_LIB"
        install_name_tool -id "$DEST_LIB" "$DEST_LIB" 2>/dev/null || true
        codesign --force --sign - "$DEST_LIB" 2>/dev/null || true
        echo "已安装：$DEST_LIB"
        exit 0
    fi
fi

echo "未检测到 Homebrew，使用系统 clang++ 直接编译官方 LibRaw-${LIBRAW_VER}…"
TMP_DIR="$(mktemp -d /tmp/phos-libraw-build.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

TARBALL="LibRaw-${LIBRAW_VER}.tar.gz"
URLS=(
    "https://www.libraw.org/data/${TARBALL}"
    "https://github.com/LibRaw/LibRaw/archive/refs/tags/${LIBRAW_VER}.tar.gz"
)

DOWNLOADED=0
for u in "${URLS[@]}"; do
    echo "下载：$u"
    if curl -fSL --connect-timeout 15 --max-time 180 -o "$TARBALL" "$u"; then
        DOWNLOADED=1
        break
    fi
done
if [ "$DOWNLOADED" -ne 1 ]; then
    echo "下载 LibRaw 源码失败，请检查网络或设置代理后重试。" >&2
    exit 1
fi

tar -xzf "$TARBALL"
SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'LibRaw*' | head -n 1)"
cd "$SRC_DIR"

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
echo "编译 LibRaw ($ARCH, SDK=$SDK_PATH)…"

if [ -x ./configure ]; then
    ./configure --disable-openmp --disable-lcms --disable-jasper --disable-examples \
        CXXFLAGS="-O2 -arch $ARCH -isysroot $SDK_PATH" \
        CFLAGS="-O2 -arch $ARCH -isysroot $SDK_PATH" \
        --prefix="$TMP_DIR/stage" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" lib/libraw.la >/dev/null
    DYLIB="$(find "$SRC_DIR" -name 'libraw*.dylib' -not -type l | head -n 1)"
else
    # GitHub archive 不带 autotools configure，直接用 clang++ 编译全部 src/**/*.cpp 为单一 libraw.dylib
    SRCS=()
    while IFS= read -r f; do SRCS+=("$f"); done < <(find src -name '*.cpp' | sort)
    clang++ -std=c++14 -O2 -fPIC -dynamiclib -arch "$ARCH" -isysroot "$SDK_PATH" \
        -I. -DLIBRAW_NOTHREADS -Wno-deprecated-declarations \
        "${SRCS[@]}" -lz -o "$TMP_DIR/libraw.dylib"
    DYLIB="$TMP_DIR/libraw.dylib"
fi

if [ -z "${DYLIB:-}" ] || [ ! -f "$DYLIB" ]; then
    echo "编译未能产出 libraw.dylib" >&2
    exit 1
fi

cp -L "$DYLIB" "$DEST_LIB"
install_name_tool -id "$DEST_LIB" "$DEST_LIB" 2>/dev/null || true
codesign --force --sign - "$DEST_LIB"

# 自检核心符号
nm -gU "$DEST_LIB" | grep -q "_libraw_init"
nm -gU "$DEST_LIB" | grep -q "_libraw_dcraw_process"
nm -gU "$DEST_LIB" | grep -q "_libraw_dcraw_make_mem_image"
echo "✓ LibRaw ${LIBRAW_VER} 已安装并验证通过：${DEST_LIB}（$(du -h "${DEST_LIB}" | awk '{print $1}')）"
