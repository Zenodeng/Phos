#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== 正在安装 Phos 全部 5 个 Core ML 端侧模型（支持 HF_ENDPOINT 镜像环境变量）==="
bash "$DIR/install_lama_model.sh"
bash "$DIR/install_sky_model.sh"
bash "$DIR/install_depth_model.sh"
bash "$DIR/install_denoise_model.sh"
bash "$DIR/install_superres_model.sh"
echo ""
echo "全部 5 个 Core ML 模型安装完成："
du -sh "$HOME/Library/Application Support/Phos/Models/"*.mlmodelc
