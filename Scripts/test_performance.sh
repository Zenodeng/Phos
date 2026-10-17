#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-regression.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
FLAGS=($PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_APP_TESTING -sdk "$SDK" -target "$PHOS_BUILD_TARGET" -module-cache-path "$OUT/module-cache")
ENGINE=(Sources/Phos/*.swift)

swiftc "${FLAGS[@]}" -D PHOS_TESTING Sources/Phos/*.swift \
    Tools/PerformanceTest.swift -o "$OUT/performance"
phos_verify_ui_binary "$OUT/performance" "$OUT/performance-build-verification.json"
"$OUT/performance"

swiftc "${FLAGS[@]}" -D PHOS_TESTING "${ENGINE[@]}" Tools/RenderRegression.swift -o "$OUT/render"
phos_verify_ui_binary "$OUT/render" "$OUT/render-build-verification.json"
if [[ $# -gt 0 ]]; then
    "$OUT/render" "$OUT/pixels" "$1"
else
    "$OUT/render" "$OUT/pixels"
fi
printf 'Regression artifacts: %s\n' "$OUT"
