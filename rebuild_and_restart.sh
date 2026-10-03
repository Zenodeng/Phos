#!/bin/bash
# 自动重新编译并重启 Phos 应用
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 正在编译 Phos..."
./build.sh

echo "🛑 关闭旧版本应用..."
killall Phos 2>/dev/null || killall RawForge 2>/dev/null || true
sleep 0.5

echo "🚀 启动新版本应用..."
"$SCRIPT_DIR/Phos.app/Contents/MacOS/Phos" &

echo "✅ 完成！应用已重启。"
