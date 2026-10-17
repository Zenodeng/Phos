#!/bin/sh
# 把源码编译并打成 .app。
# 用 swiftc 直接编译（不依赖 SwiftPM），兼容只有 Command Line Tools 的机器。
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="Phos"
MIN_MACOS="26.0"
mkdir -p build

. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx$MIN_MACOS" "build/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
swiftc -O $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -sdk "$SDK" -target "$PHOS_BUILD_TARGET" \
    Sources/Phos/*.swift -o "build/$APP_NAME"
phos_verify_ui_binary "build/$APP_NAME" "build/binary-verification.json"
echo "使用 SDK: ${SDK}（编译与链接 ${PHOS_BUILD_SDK_VERSION}）"

APP="$APP_NAME.app"
if [ -e "$APP" ]; then
    /bin/rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/PhotoAIAdapter "$APP/Contents/Resources/PhotoAIAdapter"
sh Scripts/package_icon.sh "$APP/Contents/Resources"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# 免费 ad-hoc 签名（- = 本地签名、不公证）。
# 不写 entitlements，避免 App Sandbox 破坏照片文件夹和旁车写入。
if ! codesign --force --deep --sign - "$APP"; then
    echo "代码签名失败：$APP" >&2
    exit 1
fi
phos_verify_ui_bundle "$APP" "build/bundle-verification.json"
echo "打包完成: $APP"
