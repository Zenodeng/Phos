#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="${1:-$ROOT/../outputs/Phos-V3-test/PhosVisualLab.app}"
REFERENCE="$ROOT/../outputs/Phos-V3-test/Phos.app"
. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" "arm64-apple-macosx26.0" "build/visual-lab/ui-capabilities.json"
SDK="$PHOS_BUILD_SDK"
python3 - "$APP" "$REFERENCE" "$SDK" <<'PY'
from pathlib import Path
import sys,plistlib
app,reference,sdk=(Path(p).resolve() for p in sys.argv[1:])
if app==reference or str(app).startswith('/Applications/') or not sdk.is_dir():raise SystemExit('Use a separate lab output and a valid SDK.')
if app.exists():
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 if info.get('CFBundleIdentifier') not in ['com.zeno.phos.visual-lab','com.zeno.phos.visual-lab.fallback']:raise SystemExit('Refusing to replace a non-lab App.')
PY
mkdir -p build/visual-lab/module-cache
swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -O -D PHOS_TESTING -D PHOS_APP_TESTING -sdk "$SDK" -target "$PHOS_BUILD_TARGET" \
  -module-cache-path build/visual-lab/module-cache -module-name PhosVisualLab \
  Sources/Phos/*.swift Tools/WorkspaceVisualLab.swift Tools/WorkspaceComponentGallery.swift -o build/visual-lab/PhosVisualLab \
  > build/visual-lab/compile.log 2>&1 || { cat build/visual-lab/compile.log >&2; exit 1; }
phos_verify_ui_binary build/visual-lab/PhosVisualLab build/visual-lab/binary-verification.json
python3 - "$APP" "$REFERENCE" "$SDK" <<'PY'
from pathlib import Path
import sys,shutil,tempfile,plistlib,subprocess,json,hashlib,os
app,reference,sdk=(Path(p).resolve() for p in sys.argv[1:]);app.parent.mkdir(parents=True,exist_ok=True)
temporary=Path(tempfile.mkdtemp(prefix='PhosVisualLab.stage-',dir=app.parent));stage=temporary/app.name
shutil.copytree(reference,stage);p=stage/'Contents/Info.plist';info=plistlib.loads(p.read_bytes())
(stage/'Contents/MacOS'/info['CFBundleExecutable']).unlink()
bundleID=os.environ.get('PHOS_LAB_BUNDLE_ID','com.zeno.phos.visual-lab')
if bundleID not in ['com.zeno.phos.visual-lab','com.zeno.phos.visual-lab.fallback']:raise SystemExit('Unsupported lab bundle identity.')
info.update(CFBundleIdentifier=bundleID,CFBundleName='PhosVisualLab',CFBundleDisplayName='Phos 兼容样板' if bundleID.endswith('.fallback') else 'Phos 视觉样板',CFBundleExecutable='PhosVisualLab',LSMinimumSystemVersion='26.0',PhosVisualLabFixtureFolder=str(Path('../outputs/Phos-V3-evidence/S1-A/fixtures/work').resolve()))
inputs=stage/'Contents/Resources/FixtureInputs';inputs.mkdir()
fixtures=Path('../outputs/Phos-V3-evidence/S1-A/fixtures')
shutil.copy2(fixtures/'catalog.json',inputs/'catalog.json')
for fixture in json.loads((fixtures/'catalog.json').read_text())['items']:
 shutil.copy2(fixtures/'pristine'/fixture['name'],inputs/fixture['name'])
p.write_bytes(plistlib.dumps(info));shutil.copy2('build/visual-lab/PhosVisualLab',stage/'Contents/MacOS/PhosVisualLab')
subprocess.run(['codesign','--force','--deep','--sign','-',str(stage)],check=True,capture_output=True)
subprocess.run(['python3','Scripts/ui_build_policy.py','verify',str(stage),
                'build/visual-lab/ui-capabilities.json','build/visual-lab/bundle-verification.json','--bundle'],check=True)
if app.exists():shutil.rmtree(app)
stage.replace(app);temporary.rmdir()
source=list(Path('Sources/Phos').glob('*.swift'))+[Path('Tools/WorkspaceVisualLab.swift'),Path('Tools/WorkspaceComponentGallery.swift')]
capabilities=json.loads(Path('build/visual-lab/ui-capabilities.json').read_text())
report=dict(capabilities=capabilities,appPath=str(app),sdk=str(sdk),compiler=subprocess.check_output(['swiftc','--version'],text=True).strip(),target='arm64-apple-macosx26.0',bundleID=info['CFBundleIdentifier'],sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source)},executableSHA256=hashlib.sha256((app/'Contents/MacOS/PhosVisualLab').read_bytes()).hexdigest())
reportPath=Path(os.environ.get('PHOS_EVIDENCE_DIR','../outputs/Phos-V3-evidence/S1-B'))/'build.json'
reportPath.parent.mkdir(parents=True,exist_ok=True)
reportPath.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('Built '+str(app))
PY
