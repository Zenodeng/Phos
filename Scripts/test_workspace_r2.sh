#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { printf 'Usage: bash Scripts/test_workspace.sh <output-directory>\n' >&2; exit 2; }
mkdir -p "$1"
OUTPUT="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" arm64-apple-macosx26.0 "$OUTPUT/ui-capabilities.json"
FLAGS=($PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -suppress-warnings -D PHOS_TESTING -D PHOS_APP_TESTING -D PHOS_WORKSPACE_SUITE
       -sdk "$PHOS_BUILD_SDK" -target "$PHOS_BUILD_TARGET" -module-cache-path "$OUTPUT/module-cache")
mkdir -p "$OUTPUT/test-source"
cp Sources/Phos/*.swift "$OUTPUT/test-source/"
cp Tools/WorkspaceShellTest.swift Tools/WorkspaceR2Test.swift "$OUTPUT/test-source/"
swiftc "${FLAGS[@]}" "$OUTPUT"/test-source/*.swift -o "$OUTPUT/workspace-test"
phos_verify_ui_binary "$OUTPUT/workspace-test" "$OUTPUT/workspace-build-verification.json"
"$OUTPUT/workspace-test" "$OUTPUT/workspace-test.json" | tee "$OUTPUT/workspace-test.log"
printf 'PASS: Workspace shell verification. Artifacts: %s\n' "$OUTPUT"
