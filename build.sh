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
MIN_MACOS="26.0"
mkdir -p "$SCRIPT_DIR/build"

BUILD_LOG="$SCRIPT_DIR/build/build.log"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx$MIN_MACOS" "$SCRIPT_DIR/build/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
if ! swiftc -O $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -sdk "$SDK" -target "$PHOS_BUILD_TARGET" \
    Sources/Phos/*.swift -o "$BIN" >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG" >&2
    exit 1
fi
phos_verify_ui_binary "$BIN" "$SCRIPT_DIR/build/binary-verification.json"
echo "使用 SDK: ${SDK}（编译与链接 ${PHOS_BUILD_SDK_VERSION}）"

# 先在暂存目录里组装并签名，再整体替换目标 app。
# 这样即使目标 app 正在运行，也不会因为覆盖运行中的可执行文件（ETXTBSY）而中途失败。
/bin/rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Phos"
cp Info.plist "$STAGE/Contents/Info.plist"
sh Scripts/package_icon.sh "$STAGE/Contents/Resources"
chmod +x "$STAGE/Contents/MacOS/Phos"
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
SIGN_LOG="$SCRIPT_DIR/build/codesign.log"
if ! codesign --force --deep --sign - "$STAGE" >"$SIGN_LOG" 2>&1; then
    cat "$SIGN_LOG" >&2
    echo "代码签名失败：$STAGE" >&2
    exit 1
fi
phos_verify_ui_bundle "$STAGE" "$SCRIPT_DIR/build/bundle-verification.json"

install_app() {
    target="$1"
    python3 Scripts/install_local_app.py "$STAGE" "$target" \
        --report "$SCRIPT_DIR/build/install-verification.json"
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
