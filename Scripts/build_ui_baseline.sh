#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:-$ROOT/../outputs/Phos-V3-test/PhosBaseline.app}"
REFERENCE="${2:-$ROOT/../outputs/Phos-V3-test/Phos.app}"
[[ -f "$REFERENCE/Contents/Info.plist" ]] || { printf 'Build the reference test App first: %s\n' "$REFERENCE" >&2; exit 2; }
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "build/ui-baseline/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
python3 - "$APP" "$REFERENCE" "$SDK" <<'PY'
from pathlib import Path
import sys, plistlib
app, reference, sdk = (Path(p).resolve() for p in sys.argv[1:])
if app == reference or str(app).startswith('/Applications/'):
    raise SystemExit('Baseline output must be separate from the reference and installed Apps.')
if not sdk.is_dir():
    raise SystemExit('Selected SDK does not exist: '+str(sdk))
if app.exists():
    info_path = app/'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    if info.get('CFBundleIdentifier') != 'com.zeno.phos.baseline' or not info.get('PhosBaselineHarness'):
        raise SystemExit('Refusing to replace an existing non-baseline App or directory.')
PY
mkdir -p build/ui-baseline/module-cache
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -sdk "$SDK" -target "$PHOS_BUILD_TARGET" Tools/WindowShot.swift -o build/ui-baseline/windowshot
phos_verify_ui_binary build/ui-baseline/windowshot build/ui-baseline/windowshot-verification.json
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_BASELINE -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK" -target "$PHOS_BUILD_TARGET" \
    -module-cache-path build/ui-baseline/module-cache -module-name PhosBaseline \
    Sources/Phos/*.swift Tools/UIBaseline.swift -o build/ui-baseline/PhosBaseline \
    > build/ui-baseline/compile.log 2>&1 || { cat build/ui-baseline/compile.log >&2; exit 1; }
phos_verify_ui_binary build/ui-baseline/PhosBaseline build/ui-baseline/binary-verification.json
python3 - "$APP" "$REFERENCE" "$SDK" <<'PY'
import sys, shutil, plistlib, subprocess, json, hashlib, tempfile
from pathlib import Path
app, reference, sdk = map(str, sys.argv[1:])
app = Path(app); reference = Path(reference)
if app.resolve() == reference.resolve() or str(app.resolve()).startswith('/Applications/'):
    raise SystemExit('Baseline output must be separate from the reference and installed Apps.')
app.parent.mkdir(parents=True,exist_ok=True)
stage_root = Path(tempfile.mkdtemp(prefix=app.name+'.stage-',dir=app.parent))
stage = stage_root/app.name
shutil.copytree(reference, stage)
info_path = stage/'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
old = stage/'Contents/MacOS'/info['CFBundleExecutable']
if old.exists(): old.unlink()
info.update(CFBundleIdentifier='com.zeno.phos.baseline', CFBundleName='PhosBaseline',
            CFBundleDisplayName='PhosBaseline', CFBundleExecutable='PhosBaseline',
            PhosBaselineHarness=True, LSMinimumSystemVersion='26.0')
info_path.write_bytes(plistlib.dumps(info))
shutil.copy2('build/ui-baseline/PhosBaseline', stage/'Contents/MacOS/PhosBaseline')
shutil.copy2('build/ui-baseline/windowshot', stage/'Contents/MacOS/windowshot')
subprocess.run(['codesign','--force','--deep','--sign','-',str(stage)],check=True,capture_output=True)
subprocess.run(['python3','Scripts/ui_build_policy.py','verify',str(stage),
                'build/ui-baseline/ui-capabilities.json','build/ui-baseline/bundle-verification.json','--bundle'],check=True)
if app.exists(): shutil.rmtree(app)
stage.replace(app)
stage_root.rmdir()
report=dict(appPath=str(app.resolve()), referenceApp=str(reference.resolve()), sdk=sdk,
            buildConfiguration=json.loads(Path('build/ui-baseline/ui-capabilities.json').read_text()),
            compiler=subprocess.check_output(['swiftc','--version'],text=True).strip(),
            flags=['-O','-D PHOS_BASELINE','-D PHOS_TESTING','-D PHOS_APP_TESTING','arm64-apple-macosx26.0'],
            head=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
            executableSHA256=hashlib.sha256((app/'Contents/MacOS/PhosBaseline').read_bytes()).hexdigest(),
            sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(list(Path('Sources/Phos').glob('*.swift')) + [Path('Tools/UIBaseline.swift'),Path('Tools/WindowShot.swift')])},
            standaloneHarnessIsExcludedFromNormalBuild=True)
(app.parent/'baseline-build.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('Built isolated baseline App: '+str(app.resolve()))
PY
