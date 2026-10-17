#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
    printf 'Usage: bash Scripts/test_workflow.sh <real-photo> <photographed-neutral-paper> [more-photos...]\n' >&2
    exit 2
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-workflow.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK" -target "$PHOS_BUILD_TARGET" \
    -module-cache-path "$OUT/module-cache" Sources/Phos/*.swift \
    Tools/WorkflowTest.swift -o "$OUT/test"
phos_verify_ui_binary "$OUT/test" "$OUT/binary-verification.json"
"$OUT/test" "$@"
