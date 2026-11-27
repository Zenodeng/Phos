#!/bin/bash
# 编译无头 ColorMatch 参数反解 Worker 至 build/phos-colormatch-worker
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${RF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"

mkdir -p build
swiftc -O -D PHOS_TESTING -sdk "$SDK" -target arm64-apple-macosx15.0 \
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
    Sources/Phos/SoftProofEngine.swift Sources/Phos/ColorMatchEngine.swift \
    Tools/ColorMatchDataWorker.swift -o build/phos-colormatch-worker

echo "✓ 已编译无头反解 Worker：$(pwd)/build/phos-colormatch-worker"
