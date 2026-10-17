#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-build/photo-ai-data}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" arm64-apple-macosx26.0 "$OUTPUT/ui-capabilities.json"
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$PHOS_BUILD_SDK" -target "$PHOS_BUILD_TARGET" Sources/Phos/*.swift Tools/PhotoAIData.swift -o "$OUTPUT/photo-ai-data" > "$OUTPUT/compile.log" 2>&1
phos_verify_ui_binary "$OUTPUT/photo-ai-data" "$OUTPUT/binary-verification.json"
echo "$OUTPUT/photo-ai-data"
