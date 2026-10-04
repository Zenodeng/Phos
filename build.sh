#!/bin/sh
# Phos 一键构建并安装到 /Applications（本机用，走 Command Line Tools）
# 默认安装目标：/Applications/Phos.app（即 Finder / 启动台里双击的那个）
# 想装到别处：APP_PATH=/somewhere/Phos.app ./build.sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_PATH="${APP_PATH:-/Applications/Phos.app}"
LOCAL_APP="$SCRIPT_DIR/Phos.app"
BIN="$SCRIPT_DIR/build/Phos"
STAGE="$SCRIPT_DIR/build/Phos.app.stage"
MIN_MACOS="15.0"
mkdir -p "$SCRIPT_DIR/build"

# xcrun 返回的 SDK 可能比当前 Swift 编译器新；按顺序尝试可用 SDK。
CANDIDATES="${RF_SDK:-}"
CANDIDATES="$CANDIDATES $(xcrun --show-sdk-path 2>/dev/null || true)"
for f in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
    CANDIDATES="$CANDIDATES $f"
done

BUILD_LOG="$SCRIPT_DIR/build/build.log"
BUILT=0
for SDK in $CANDIDATES; do
    [ -d "$SDK" ] || continue
    # 用版本不匹配的 SDK 试编译会刷一大段报错，先收进日志；
    # 只有全部 SDK 都失败时才把它打出来，避免误以为构建挂了。
    if swiftc -O -sdk "$SDK" -target "arm64-apple-macosx$MIN_MACOS" \
        Sources/Phos/*.swift -o "$BIN" >"$BUILD_LOG" 2>&1; then
        echo "使用 SDK: $SDK"
        WARNS=$(grep -c "warning:" "$BUILD_LOG" || true)
        if [ "$WARNS" -gt 0 ]; then
            echo "编译警告 $WARNS 条（完整输出见 build/build.log）"
        fi
        BUILT=1
        break
    fi
done
if [ "$BUILT" != "1" ]; then
    echo "所有 SDK 都编译失败，最后一次编译输出：" >&2
    cat "$BUILD_LOG" >&2
    exit 1
fi

# 先在暂存目录里组装并签名，再整体替换目标 app。
# 这样即使目标 app 正在运行，也不会因为覆盖运行中的可执行文件（ETXTBSY）而中途失败。
/bin/rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Phos"
cp Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
chmod +x "$STAGE/Contents/MacOS/Phos"
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
SIGN_LOG="$SCRIPT_DIR/build/codesign.log"
if ! codesign --force --deep --sign - "$STAGE" >"$SIGN_LOG" 2>&1; then
    cat "$SIGN_LOG" >&2
    echo "代码签名失败：$STAGE" >&2
    exit 1
fi

install_app() {
    target="$1"
    mkdir -p "$(dirname "$target")"
    /bin/rm -rf "$target"
    /bin/cp -R "$STAGE" "$target"
}

install_app "$APP_PATH"
echo "已构建并安装到 $APP_PATH"

# 默认不再往仓库里留副本。
# 仓库在桌面上，而 LaunchServices 会持续扫描桌面 —— 留在仓库里的 Phos.app
# 会在启动台 / 聚焦里一直显示成一个重复的应用。确实需要时显式打开：
#   KEEP_LOCAL_APP=1 ./build.sh
if [ "${KEEP_LOCAL_APP:-0}" = "1" ] && [ "$APP_PATH" != "$LOCAL_APP" ]; then
    install_app "$LOCAL_APP"
    echo "同步更新项目内副本 $LOCAL_APP（KEEP_LOCAL_APP=1）"
fi
