#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: bash Scripts/test_studio.sh <fixture-image> <output-directory> [render-baseline-directory]\n' >&2
    exit 2
fi
[[ -f "$1" ]] || { printf 'Fixture image not found: %s\n' "$1" >&2; exit 2; }
BASELINE=()
if [[ $# -eq 3 ]]; then
    [[ -d "$3" ]] || { printf 'Render baseline must be a directory: %s\n' "$3" >&2; exit 2; }
    BASELINE=("$(cd "$3" && pwd)")
fi
IMAGE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$2"
OUTPUT="$(cd "$2" && pwd)"
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-studio.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUTPUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
printf 'Studio test SDK: %s\n' "$SDK"
FLAGS=($PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -suppress-warnings -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK"
       -target "$PHOS_BUILD_TARGET" -module-cache-path "$BUILD/module-cache")

swiftc "${FLAGS[@]}" Sources/Phos/*.swift Tools/StudioLayoutTest.swift -o "$BUILD/layout"
phos_verify_ui_binary "$BUILD/layout" "$OUTPUT/layout-build-verification.json"
"$BUILD/layout" "$IMAGE" "$OUTPUT" | tee "$OUTPUT/layout.log"
swiftc "${FLAGS[@]}" Sources/Phos/*.swift Tools/PerformanceTest.swift -o "$BUILD/performance"
phos_verify_ui_binary "$BUILD/performance" "$OUTPUT/performance-build-verification.json"
"$BUILD/performance" | tee "$OUTPUT/performance.log"
swiftc "${FLAGS[@]}" Sources/Phos/*.swift Tools/RenderRegression.swift -o "$BUILD/render"
phos_verify_ui_binary "$BUILD/render" "$OUTPUT/render-build-verification.json"
"$BUILD/render" "$OUTPUT/render" "${BASELINE[@]}" | tee "$OUTPUT/render.log"
printf 'PASS: Studio verification complete. Artifacts: %s\n' "$OUTPUT"
