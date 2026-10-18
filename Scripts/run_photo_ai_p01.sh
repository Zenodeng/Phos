#!/bin/bash
# Replays P0/P1 preparation only. Never trains or installs model weights.
set -euo pipefail
PHOS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
PHOS_TASK_ROOT="${PHOS_TASK_ROOT:-$(dirname "$PHOS_REPO")/outputs/Phos-P0-P1-20261018}"
PHOS_LEGACY_ROOT="$(dirname "$PHOS_REPO")/outputs/Phos-Training-Week2-20261017"
PHOS_TRAINING_PYTHON="${PHOS_TRAINING_PYTHON:-$PHOS_LEGACY_ROOT/.venv/bin/python}"
PHOS_TASK_WORKER="${PHOS_TASK_WORKER:-$PHOS_TASK_ROOT/worker-final/photo-ai-data}"
PHOS_CHECK_ROOT="${PHOS_CHECK_ROOT:-$PHOS_TASK_ROOT/checks-phos-json-compact-v1}"
case "${1:---help}" in
 --help) echo 'Usage: run_photo_ai_p01.sh collect|prepare|refusals|audit|verify-protocol|preflight|evaluate-base|evaluate-incumbent|evaluate-candidate'; exit 0;;
 collect|prepare|refusals|audit) "$PHOS_TRAINING_PYTHON" "$PHOS_REPO/Scripts/photo_ai_p01.py" "$1" --root "$PHOS_TASK_ROOT" --legacy "$PHOS_LEGACY_ROOT" --worker "$PHOS_TASK_WORKER";;
 verify-protocol|preflight)
   "$PHOS_TRAINING_PYTHON" "$PHOS_REPO/Scripts/verify_photo_ai_protocol.py" --root "$PHOS_TASK_ROOT" --model "$HOME/Library/Application Support/Phos/MLX/model" --out "$PHOS_CHECK_ROOT/sft"
   if [ "$1" = preflight ]; then
     "$PHOS_TRAINING_PYTHON" "$PHOS_REPO/Scripts/photo_ai_train_p2.py" preflight --model "$HOME/Library/Application Support/Phos/MLX/model" --data "$PHOS_CHECK_ROOT/sft" --out "$PHOS_CHECK_ROOT/token-preflight" --max-seq-length 3072 --layers 4 --rank 8 --iters 1
   fi;;
 evaluate-base|evaluate-incumbent|evaluate-candidate)
   PHOS_VARIANT="${1#evaluate-}"; PHOS_ADAPTER_ARGS=()
   if [ "$PHOS_VARIANT" = incumbent ]; then PHOS_ADAPTER_ARGS=(--adapter "$PHOS_TASK_ROOT/baseline/incumbent-adapter"); fi
   if [ "$PHOS_VARIANT" = candidate ]; then PHOS_ADAPTER_ARGS=(--adapter "${PHOS_ADAPTER_DIR:?Set PHOS_ADAPTER_DIR for candidate evaluation}"); fi
   "$PHOS_TRAINING_PYTHON" "$PHOS_REPO/Scripts/evaluate_photo_ai_p01.py" --root "$PHOS_TASK_ROOT" --out "$PHOS_CHECK_ROOT/evaluation-$PHOS_VARIANT" --model "$HOME/Library/Application Support/Phos/MLX/model" --worker "$PHOS_TASK_WORKER" --variant "$PHOS_VARIANT" --retries "${PHOS_EVAL_RETRIES:-0}" ${PHOS_ADAPTER_ARGS[@]+"${PHOS_ADAPTER_ARGS[@]}"};;
 *) echo 'Unknown stage; use --help' >&2; exit 2;;
esac
