#!/bin/sh
# 把源码编译并打成 .app。
# 用 swiftc 直接编译（不依赖 SwiftPM）——本机只有 Command Line Tools 时 SwiftPM 的
# swift-package 常常不可用，swiftc 这条路径在 CLT 和完整 Xcode 上都稳。
set -e
APP_NAME="RawForge"
MIN_MACOS="15.0"

mkdir -p build

# SDK 逐个试：有的机器上 xcrun 给的 SDK 比编译器新（本机就是 27.0 SDK + Swift 6.3.3），
# 编译会直接报 "this SDK is not supported by the compiler"，所以回退到可用的旧 SDK
CANDIDATES="$(xcrun --show-sdk-path 2>/dev/null || true)"
for f in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do CANDIDATES="$CANDIDATES $f"; done
BUILT=0
for SDK in $CANDIDATES; do
  [ -d "$SDK" ] || continue
  if swiftc -O -sdk "$SDK" -target "arm64-apple-macosx$MIN_MACOS" \
       Sources/RawForge/*.swift -o "build/$APP_NAME" 2>/dev/null; then
    echo "使用 SDK: $SDK"
    BUILT=1
    break
  fi
done
[ "$BUILT" = "1" ] || { echo "所有 SDK 都编译失败" >&2; exit 1; }

APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# 免费 ad-hoc 签名（- = 本地签名、不公证）
# 不写任何 entitlements —— 一旦 App Sandbox 生效，读照片文件夹 / 写 .rawforge.json 旁挂会全部失效
codesign --force --deep --sign - "$APP" || true
echo "打包完成: $APP"
