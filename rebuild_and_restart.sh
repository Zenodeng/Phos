#!/bin/bash
# 自动重新编译并重启 Phos 应用
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP="/Applications/Phos.app"

echo "🔨 正在编译 Phos..."
./build.sh

echo "🛑 关闭旧版本应用..."
pkill -x Phos 2>/dev/null || killall RawForge 2>/dev/null || true
sleep 0.5

echo "🚀 启动新版本应用..."
# 用 open 走 LaunchServices，和双击图标是同一条路径
open "$APP"

echo "✅ 完成！应用已重启。"
echo "   确认加载的是新二进制："
echo "   lsof -p \"\$(pgrep -x Phos)\" | awk '\$4==\"txt\"' | grep Phos.app"
