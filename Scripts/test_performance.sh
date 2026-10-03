#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-regression.XXXXXX")"
FLAGS=(-O -sdk "$SDK" -target arm64-apple-macosx15.0 -module-cache-path "$OUT/module-cache")
ENGINE=(Sources/Phos/*.swift)

swiftc "${FLAGS[@]}" -D PHOS_TESTING Sources/Phos/*.swift \
    Tools/PerformanceTest.swift -o "$OUT/performance"
"$OUT/performance"

swiftc "${FLAGS[@]}" -D PHOS_TESTING "${ENGINE[@]}" Tools/RenderRegression.swift -o "$OUT/render"
if [[ $# -gt 0 ]]; then
    "$OUT/render" "$OUT/pixels" "$1"
else
    "$OUT/render" "$OUT/pixels"
fi
printf 'Regression artifacts: %s\n' "$OUT"
