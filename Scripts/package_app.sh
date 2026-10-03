#!/bin/sh
# 把源码编译并打成 .app。
# 用 swiftc 直接编译（不依赖 SwiftPM），兼容只有 Command Line Tools 的机器。
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="Phos"
MIN_MACOS="15.0"
mkdir -p build

# SDK 逐个试：有的机器上 xcrun 给的 SDK 比编译器新，会导致 SDK 不兼容。
CANDIDATES="${RF_SDK:-}"
CANDIDATES="$CANDIDATES $(xcrun --show-sdk-path 2>/dev/null || true)"
for f in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
    CANDIDATES="$CANDIDATES $f"
done

BUILT=0
for SDK in $CANDIDATES; do
    [ -d "$SDK" ] || continue
    if swiftc -O -sdk "$SDK" -target "arm64-apple-macosx$MIN_MACOS" \
        Sources/Phos/*.swift -o "build/$APP_NAME"; then
        echo "使用 SDK: $SDK"
        BUILT=1
        break
    fi
done
[ "$BUILT" = "1" ] || { echo "所有 SDK 都编译失败" >&2; exit 1; }

APP="$APP_NAME.app"
if [ -e "$APP" ]; then
    /bin/rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# 免费 ad-hoc 签名（- = 本地签名、不公证）。
# 不写 entitlements，避免 App Sandbox 破坏照片文件夹和旁车写入。
if ! codesign --force --deep --sign - "$APP"; then
    echo "代码签名失败：$APP" >&2
    exit 1
fi
echo "打包完成: $APP"
