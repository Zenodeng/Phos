#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d "${TMPDIR:-/tmp}/phos-p012-upgrade.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
FLAGS=($PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK" -target "$PHOS_BUILD_TARGET" -module-cache-path "$OUT/module-cache")

swiftc "${FLAGS[@]}" Sources/Phos/*.swift Tools/UpgradeVerificationTest.swift -o "$OUT/upgrade_verify"
"$OUT/upgrade_verify"
rm -rf "$OUT"
