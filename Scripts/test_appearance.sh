#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: sh Scripts/test_appearance.sh <app-bundle> <output-directory>" >&2
    exit 2
fi
APP="$(CDPATH= cd -- "$1" && pwd)"
mkdir -p "$2"
OUTPUT="$(CDPATH= cd -- "$2" && pwd)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/phos-appearance.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUTPUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -suppress-warnings -D PHOS_APPEARANCE_TEST -sdk "$SDK" \
    -target "$PHOS_BUILD_TARGET" -module-cache-path "$BUILD/module-cache" \
    Sources/Phos/*.swift Tools/AppearanceTest.swift -o "$BUILD/appearance-test"
phos_verify_ui_binary "$BUILD/appearance-test" "$OUTPUT/binary-verification.json"
xcrun assetutil --info "$APP/Contents/Resources/Assets.car" >"$OUTPUT/catalog.json"
"$BUILD/appearance-test" "$APP" "$OUTPUT" "$OUTPUT/catalog.json"
