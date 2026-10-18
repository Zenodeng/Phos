#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || exit 2
mkdir -p "$1"
OUTPUT="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" arm64-apple-macosx26.0 "$OUTPUT/ui-capabilities.json"
mkdir -p "$OUTPUT/test-source"
cp Sources/Phos/*.swift Tools/WorkspaceShellTest.swift Tools/WorkspaceR2Test.swift Tools/WorkspaceR3Test.swift Tools/WorkspaceR4Test.swift "$OUTPUT/test-source/"
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -suppress-warnings -D PHOS_TESTING -D PHOS_APP_TESTING -D PHOS_WORKSPACE_SUITE -D PHOS_WORKSPACE_R3_SUITE -D PHOS_WORKSPACE_R4_SUITE \
  -sdk "$PHOS_BUILD_SDK" -target "$PHOS_BUILD_TARGET" -module-cache-path "$OUTPUT/module-cache" \
  "$OUTPUT"/test-source/*.swift -o "$OUTPUT/workspace-test"
phos_verify_ui_binary "$OUTPUT/workspace-test" "$OUTPUT/workspace-build-verification.json"
"$OUTPUT/workspace-test" "$OUTPUT/workspace-test.json" | tee "$OUTPUT/workspace-test.log"
