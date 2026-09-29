#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
    printf 'Usage: bash Scripts/test_studio.sh <fixture-image> <output-directory>\n' >&2
    exit 2
fi
IMAGE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$2"
OUTPUT="$(cd "$2" && pwd)"
cd "$(dirname "$0")/.."
SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-studio.XXXXXX")"
FLAGS=(-O -suppress-warnings -D RAWFORGE_TESTING -sdk "$SDK"
       -target arm64-apple-macosx15.0 -module-cache-path "$BUILD/module-cache")

swiftc "${FLAGS[@]}" Sources/RawForge/*.swift Tools/StudioLayoutTest.swift -o "$BUILD/layout"
"$BUILD/layout" "$IMAGE" "$OUTPUT" | tee "$OUTPUT/layout.log"
swiftc "${FLAGS[@]}" Sources/RawForge/*.swift Tools/PerformanceTest.swift -o "$BUILD/performance"
"$BUILD/performance" | tee "$OUTPUT/performance.log"
swiftc "${FLAGS[@]}" Sources/RawForge/*.swift Tools/RenderRegression.swift -o "$BUILD/render"
"$BUILD/render" "$OUTPUT/render" "$IMAGE" | tee "$OUTPUT/render.log"
printf 'PASS: Studio verification complete. Artifacts: %s\n' "$OUTPUT"
