#!/bin/sh
# Build the real application with a separate identity and copy-only photo editing.
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/qa_workspace.py" build "$@"
