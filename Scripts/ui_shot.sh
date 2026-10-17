#!/bin/bash
# Capture production StudioMainWindow content through an isolated native test App.
# Never replaces /Applications, kills a production process or changes its preferences.
# Usage: bash Scripts/ui_shot.sh <output.png> --app <PhosBaseline.app>
#        [--no-build] [--reference-app <Phos.app>] [--fixture-folder <fixtures/work>]
#        [--photo <filename>] [--size <content-WxH>] [--appearance light|dark]
# External CUA native capture returns JPEG on this host; use an output.jpg path.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT=""
APP=""
REFERENCE="$ROOT/../outputs/Phos-V3-test/Phos.app"
FIXTURES="$ROOT/../outputs/Phos-V3-evidence/S0/fixtures/work"
PHOTO=""
SIZE="1440x900"
APPEARANCE="light"
BACKEND="windowshot"
BUILD=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) BUILD=0; shift ;;
        --app|--reference-app|--fixture-folder|--photo|--size|--appearance|--capture-backend)
            [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            case "$1" in
                --app) APP="$2" ;;
                --reference-app) REFERENCE="$2" ;;
                --fixture-folder) FIXTURES="$2" ;;
                --photo) PHOTO="$2" ;;
                --size) SIZE="$2" ;;
                --appearance) APPEARANCE="$2" ;;
                --capture-backend) BACKEND="$2" ;;
            esac
            shift 2 ;;
        -*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) [[ -z "$OUT" ]] || { printf 'Exactly one output is required\n' >&2; exit 2; }; OUT="$1"; shift ;;
    esac
done
[[ -n "$OUT" && -n "$APP" ]] || { printf 'An output and explicit --app path are required\n' >&2; exit 2; }
OUT="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$OUT")"
APP="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$APP")"
FIXTURES="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$FIXTURES")"
[[ "$SIZE" =~ ^[0-9]+x[0-9]+$ ]] || { printf 'Invalid content size\n' >&2; exit 2; }
[[ "$APPEARANCE" == light || "$APPEARANCE" == dark ]] || { printf 'Appearance must be light or dark\n' >&2; exit 2; }
[[ "$APP" != /Applications/* ]] || { printf 'Use an isolated test App outside /Applications\n' >&2; exit 2; }
[[ ! -e "$OUT" && ! -e "$OUT.json" ]] || { printf 'Use a fresh output path; existing evidence must not be reused\n' >&2; exit 2; }
if [[ "$BUILD" == 1 ]]; then
    bash Scripts/build_ui_baseline.sh "$APP" "$REFERENCE"
fi
python3 - "$APP" "$FIXTURES" <<'PHOS_S0_VALIDATE'
from pathlib import Path
import sys,plistlib
app=Path(sys.argv[1]).resolve(); folder=Path(sys.argv[2]).resolve()
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info.get('PhosBaselineHarness') and info.get('CFBundleIdentifier')=='com.zeno.phos.baseline', 'Expected the isolated baseline build'
assert folder.name=='work' and folder.parent.name=='fixtures' and (folder.parent/'catalog.json').exists(), 'Expected catalogued fixtures/work'
assert (app/'Contents/MacOS/windowshot').is_file(), 'Missing window capture tool; rebuild the baseline App'
PHOS_S0_VALIDATE
mkdir -p "$(dirname "$OUT")"
ARGS=(capture --folder "$FIXTURES" --output "$OUT" --size "$SIZE" --appearance "$APPEARANCE" --capture-backend "$BACKEND")
if [[ -n "$PHOTO" ]]; then ARGS+=(--photo "$PHOTO"); fi
/usr/bin/open -n -F -W -a "$APP" --stdout "$OUT.launch.log" --stderr "$OUT.launch-error.log" --args "${ARGS[@]}"
[[ -s "$OUT" && -s "$OUT.json" ]] || { printf 'Capture or geometry evidence is missing\n' >&2; exit 1; }
if [[ "$BACKEND" == windowshot ]]; then
    [[ -s "$OUT.window.json" ]] || { printf 'Window capture evidence is missing\n' >&2; exit 1; }
fi
printf 'Verified native window screenshot: %s\n' "$OUT"
