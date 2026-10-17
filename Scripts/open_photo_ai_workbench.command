#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHOS_DATA_ROOT="${1:-../outputs/Phos-Training-20261017}"
PHOS_DATA_PYTHON="$PHOS_DATA_ROOT/.venv/bin/python"
PHOS_DATA_WORKER="$PHOS_DATA_ROOT/worker/photo-ai-data"
if [[ ! -x "$PHOS_DATA_PYTHON" || ! -x "$PHOS_DATA_WORKER" ]]; then
    echo "缺少工作台环境，请先按 Tools/PhotoAIData/README.md 配置。"
    exit 1
fi
echo "浏览器打开 http://127.0.0.1:8766；关闭此终端或按 Control-C 停止审核服务。"
exec "$PHOS_DATA_PYTHON" Scripts/photo_ai_workbench.py --root "$PHOS_DATA_ROOT" --worker "$PHOS_DATA_WORKER" review
