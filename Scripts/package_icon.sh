#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
PROJECT_ROOT="$PWD"
DESTINATION="${1:?Usage: sh Scripts/package_icon.sh <bundle-resources-directory>}"
mkdir -p "$DESTINATION"
DESTINATION="$(CDPATH= cd -- "$DESTINATION" && pwd)"
ICON_WORK=""
trap 'if [ -n "$ICON_WORK" ]; then rm -rf "$ICON_WORK"; fi' EXIT HUP INT TERM

XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p')"
ICON_RESOURCES="$PROJECT_ROOT/Resources"
if [ "${XCODE_MAJOR:-0}" -ge 26 ] && xcrun --find actool >/dev/null 2>&1; then
    mkdir -p "$PROJECT_ROOT/build"
    ICON_WORK="$(mktemp -d "$PROJECT_ROOT/build/icon-compiled.XXXXXX")"
    ICON_RESOURCES="$ICON_WORK"
    if ! xcrun actool --compile "$ICON_RESOURCES" \
        --platform macosx --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_RESOURCES/partial.plist" \
        "$PROJECT_ROOT/Resources/AppIcon.icon" >"$ICON_WORK/actool.log" 2>&1; then
        cat "$ICON_WORK/actool.log" >&2
        exit 1
    fi
fi

# The checked-in compiled resources remain the fallback for Command Line Tools hosts.
for FILE in AppIcon.icns Assets.car; do
    [ -s "$ICON_RESOURCES/$FILE" ] || {
        echo "Missing compiled icon: $ICON_RESOURCES/$FILE" >&2
        exit 1
    }
    cp "$ICON_RESOURCES/$FILE" "$DESTINATION/$FILE"
done
for FILE in icon-light-1024.png icon-dark-1024.png; do
    cp "$PROJECT_ROOT/Resources/$FILE" "$DESTINATION/$FILE"
done

# The same owned protocol implementation must ship in every production/QA bundle.
mkdir -p "$DESTINATION/PhotoAIRuntime"
cp "$PROJECT_ROOT/Scripts/photo_ai_protocol.py" "$PROJECT_ROOT/Scripts/photo_ai_server.py" "$DESTINATION/PhotoAIRuntime/"
cp "$PROJECT_ROOT/Tools/OptionalModel/model-manifest.json" "$DESTINATION/PhotoAIRuntime/"
# The small, hash-pinned pilot ships with Phos; the 3.1 GB base stays external.
ditto "$PROJECT_ROOT/Resources/PhotoAIAdapter" "$DESTINATION/PhotoAIAdapter"
