#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 ]]; then
    printf 'Usage: bash Scripts/test_workflow.sh <real-photo> <photographed-neutral-paper> [more-photos...]\n' >&2
    exit 2
fi
SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawforge-workflow.XXXXXX")"
swiftc -O -D RAWFORGE_TESTING -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -module-cache-path "$OUT/module-cache" Sources/RawForge/*.swift \
    Tools/WorkflowTest.swift -o "$OUT/test"
"$OUT/test" "$@"
