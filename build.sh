#!/bin/sh
# RawForge 一键构建并安装到 /Applications（本机用，走 Command Line Tools）
set -e
# 本机 Swift 6.3.3 配不上 27.0 SDK，固定用 26.5；换机器时把这里改成你实际的 SDK
SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
BIN=/tmp/rfbuild
APP="/Applications/RawForge.app"
swiftc -O -sdk "$SDK" -target arm64-apple-macosx15.0 \
  Sources/RawForge/*.swift -o "$BIN"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RawForge"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/RawForge"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "已构建并安装到 $APP"
