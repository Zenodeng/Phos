#!/bin/sh
# Shared SDK, required core API probe, link flags and output verification for App/UI builds.
# Call from the repository root. SDK paths are quoted separately from flag tokens.
phos_ui_compile_flags() {
    PHOS_UI_SWIFT_FLAGS=""
    PHOS_UI_LINK_FLAGS=""
    PHOS_BUILD_SDK=""
    PHOS_BUILD_SDK_VERSION=""
    PHOS_BUILD_MIN_MACOS=""
    PHOS_BUILD_TARGET="${2:-arm64-apple-macosx26.0}"
    PHOS_UI_CONFIGURATION="$3"
    phos_probe_work="$(mktemp -d "${TMPDIR:-/tmp}/phos-glass-probe.XXXXXX")" || return 1
    if ! python3 Scripts/ui_build_policy.py configure "${1:-}" "$PHOS_BUILD_TARGET" \
        "$PHOS_UI_CONFIGURATION" >"$phos_probe_work/sdk-fields.txt"; then
        rm -rf "$phos_probe_work"
        return 1
    fi
    {
        IFS= read -r PHOS_BUILD_SDK
        IFS= read -r PHOS_BUILD_SDK_VERSION
        IFS= read -r PHOS_BUILD_MIN_MACOS
    } <"$phos_probe_work/sdk-fields.txt"
    if swiftc -typecheck -sdk "$PHOS_BUILD_SDK" -target "$PHOS_BUILD_TARGET" \
        -module-cache-path "$phos_probe_work/cache" Tools/NativeGlassCompileProbe.swift \
        >"$phos_probe_work/native.log" 2>&1; then
        if ! python3 Scripts/ui_build_policy.py probe-result "$PHOS_UI_CONFIGURATION" \
            Tools/NativeGlassCompileProbe.swift "$phos_probe_work/native.log" passed; then
            rm -rf "$phos_probe_work"
            return 1
        fi
        PHOS_UI_SWIFT_FLAGS="-D PHOS_NATIVE_GLASS"
        PHOS_UI_LINK_FLAGS="-Xlinker -platform_version -Xlinker macos -Xlinker $PHOS_BUILD_MIN_MACOS -Xlinker $PHOS_BUILD_SDK_VERSION"
        rm -rf "$phos_probe_work"
        return 0
    fi
    python3 Scripts/ui_build_policy.py probe-result "$PHOS_UI_CONFIGURATION" \
        Tools/NativeGlassCompileProbe.swift "$phos_probe_work/native.log" failed || {
        rm -rf "$phos_probe_work"
        return 1
    }
    printf 'Phos UI build blocked: required macOS 26 glass API probe failed. SDK: %s\nDiagnostics: %s\n' \
        "$PHOS_BUILD_SDK" "$PHOS_UI_CONFIGURATION" >&2
    rm -rf "$phos_probe_work"
    return 1
}

phos_verify_ui_binary() {
    python3 Scripts/ui_build_policy.py verify "$1" "$PHOS_UI_CONFIGURATION" "$2"
}

phos_verify_ui_bundle() {
    python3 Scripts/ui_build_policy.py verify "$1" "$PHOS_UI_CONFIGURATION" "$2" --bundle
}
