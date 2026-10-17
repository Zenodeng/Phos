#!/bin/bash
set -euo pipefail
if [[ $# -lt 3 ]]; then
    printf 'Usage: bash Scripts/test_real_photos.sh <output> <soak-seconds> <photo> [more-photos...]\n' >&2
    exit 2
fi
mkdir -p "$1"
OUTPUT="$(cd "$1" && pwd)"
SECONDS_TO_RUN="$2"
shift 2
PHOTOS=()
for photo in "$@"; do
    [[ -f "$photo" ]] || { printf 'Missing photo: %s\n' "$photo" >&2; exit 2; }
    PHOTOS+=("$(cd "$(dirname "$photo")" && pwd)/$(basename "$photo")")
done
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-real.XXXXXX")"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "$OUTPUT/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -suppress-warnings -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK" \
    -target "$PHOS_BUILD_TARGET" -module-cache-path "$BUILD/cache" \
    Sources/Phos/*.swift Tools/RealPhotoTest.swift -o "$BUILD/real-photo"
phos_verify_ui_binary "$BUILD/real-photo" "$OUTPUT/binary-verification.json"
"$BUILD/real-photo" "$OUTPUT" "$SECONDS_TO_RUN" "${PHOTOS[@]}" | tee "$OUTPUT/real-photo.log"
