#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP=""
OUT=""
FOLDER="$ROOT/../outputs/Phos-V3-evidence/S0/fixtures/work"
SAMPLES=20
SIZE=1440x900
APPEARANCE=light
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || { printf 'Every option needs a value.\n' >&2; exit 2; }
    case "$1" in
        --app) APP="$2" ;;
        --out) OUT="$2" ;;
        --fixture-folder) FOLDER="$2" ;;
        --samples) SAMPLES="$2" ;;
        --size) SIZE="$2" ;;
        --appearance) APPEARANCE="$2" ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift 2
done
[[ -n "$APP" && -n "$OUT" ]] || { printf 'Usage: %s --app PhosBaseline.app --out fresh-results.json [--samples 20]\n' "$0" >&2; exit 2; }
APP="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$APP")"
OUT="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$OUT")"
FOLDER="$(python3 -c 'import pathlib,sys;print(pathlib.Path(sys.argv[1]).resolve())' "$FOLDER")"
python3 - "$APP" "$OUT" "$FOLDER" <<'PY'
from pathlib import Path
import plistlib, sys, hashlib, json, shutil
app, output, folder = (Path(p).resolve() for p in sys.argv[1:])
if str(app).startswith('/Applications/'):
    raise SystemExit('Benchmark must use an independent test App.')
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.zeno.phos.baseline' or not info.get('PhosBaselineHarness'):
    raise SystemExit('Only PhosBaseline.app is accepted.')
if output.exists():
    raise SystemExit('Use a fresh output path so old measurements cannot be mistaken for this run.')
if folder.name != 'work' or folder.parent.name != 'fixtures' or not (folder.parent/'catalog.json').is_file():
    raise SystemExit('Use a catalogued fixtures/work folder.')
output.parent.mkdir(parents=True, exist_ok=True)
catalog = json.loads((folder.parent/'catalog.json').read_text())
for fixture in catalog['items']:
    assert hashlib.sha256((folder/fixture['name']).read_bytes()).hexdigest() == fixture['sha256'], 'Fixture image changed'
# Preserve earlier test edits, then benchmark the neutral fixed fixture set.
sidecars = sorted(folder.glob('*.rawforge.json'))
saved = output.with_name(output.name + '.sidecars-before')
if sidecars:
    saved.mkdir(exist_ok=False)
    for path in sidecars:
        shutil.move(str(path), str(saved/path.name))
output.with_name(output.name + '.fixture-state.json').write_text(json.dumps(dict(
    fixtureFolder=str(folder),initialEdits='neutral; no test sidecars',
    preservedPreviousSidecars=[str(saved/p.name) for p in sidecars]),ensure_ascii=False,indent=2))
PY
/usr/bin/open -n -F -W -a "$APP" --stdout "$OUT.launch.log" --stderr "$OUT.launch-error.log" --args \
    benchmark --folder "$FOLDER" --output "$OUT" --samples "$SAMPLES" --size "$SIZE" --appearance "$APPEARANCE"
python3 - "$OUT" "$SAMPLES" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
for name, metric in result['metrics'].items():
    if isinstance(metric, dict) and 'samplesMs' in metric:
        assert metric['count'] == len(metric['samplesMs']) > 0, name
        if name != 'mainRunLoopTimerIntervals':
            assert metric['count'] == int(sys.argv[2]), name
assert result['bundleID'] == 'com.zeno.phos.baseline'
print('PASS quantitative baseline: '+sys.argv[1])
PY
