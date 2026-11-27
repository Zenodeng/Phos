#!/bin/bash
# 验证 Guided Upright、全景拼接、Adobe DCP / LibRaw、ColorSync 软打样与 XMP 蒙版双向读写。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/phos-v48-test.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

swiftc -O -D PHOS_TESTING -sdk "$SDK" -target arm64-apple-macosx15.0 \
    -module-cache-path "$OUT/module-cache" \
    Sources/Phos/Models.swift Sources/Phos/Workflow.swift Sources/Phos/Engine.swift \
    Sources/Phos/CLUT.swift Sources/Phos/Performance.swift Sources/Phos/Alignment.swift \
    Sources/Phos/Localization.swift Sources/Phos/LocalizationCatalog.swift \
    Sources/Phos/LensProfiles.swift Sources/Phos/LensProfileEngine.swift \
    Sources/Phos/MetadataIO.swift Sources/Phos/XMPSidecar.swift \
    Sources/Phos/MetalShaders.swift Sources/Phos/MetalEngine.swift \
    Sources/Phos/MaskEngine.swift Sources/Phos/RetouchEngine.swift \
    Sources/Phos/DepthEngine.swift Sources/Phos/NeuralDenoiseEngine.swift \
    Sources/Phos/GuidedUprightEngine.swift Sources/Phos/PanoramaEngine.swift \
    Sources/Phos/LibRawEngine.swift Sources/Phos/DCPProfileEngine.swift \
    Sources/Phos/SoftProofEngine.swift \
    Tools/V48FeaturesTest.swift -o "$OUT/test"

"$OUT/test"
