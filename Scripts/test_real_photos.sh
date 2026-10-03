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
SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-real.XXXXXX")"
swiftc -O -suppress-warnings -D PHOS_TESTING -sdk "$SDK" \
    -target arm64-apple-macosx15.0 -module-cache-path "$BUILD/cache" \
    Sources/Phos/*.swift Tools/RealPhotoTest.swift -o "$BUILD/real-photo"
"$BUILD/real-photo" "$OUTPUT" "$SECONDS_TO_RUN" "${PHOTOS[@]}" | tee "$OUTPUT/real-photo.log"
