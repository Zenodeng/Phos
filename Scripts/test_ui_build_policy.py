#!/usr/bin/env python3
"""Exercise real SDK links and failure propagation without launching or installing Phos."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--sdk', action='append', required=True)
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    records = []
    environment = dict(os.environ)
    environment.pop('PHOS_DISABLE_NATIVE_GLASS', None)
    real_swiftc = shutil.which('swiftc')
    assert real_swiftc

    def command(label, argv, *, cwd=REPO, env=None, success=True):
        result = subprocess.run(argv, cwd=cwd, env=env or environment, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / (label + '.log')).write_text(result.stdout)
        assert (result.returncode == 0) == success, (label, result.returncode, result.stdout[-2400:])
        records.append(dict(case=label, expected='success' if success else 'blocked',
                            actualExitCode=result.returncode, status='passed'))
        return result

    helper = '. ./Scripts/ui_compile_flags.sh; phos_ui_compile_flags "$R1_SDK" arm64-apple-macosx26.0 "$R1_CASE/config.json"'
    tiny = out / 'PolicyMain.swift'
    tiny.write_text('@main enum PolicyMain { static func main() {} }\n')
    configs = []
    for i, sdk in enumerate(args.sdk):
        case = out / ('sdk-' + str(i)); case.mkdir()
        env = dict(environment, R1_SDK=sdk, R1_CASE=str(case), R1_MAIN=str(tiny))
        command('sdk-' + str(i), ['/bin/sh', '-eu', '-c', helper + '; '
                'swiftc $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -sdk "$PHOS_BUILD_SDK" '
                '-target "$PHOS_BUILD_TARGET" -module-cache-path "$R1_CASE/cache" '
                'Tools/NativeGlassCompileProbe.swift "$R1_MAIN" -o "$R1_CASE/probe"; '
                'phos_verify_ui_binary "$R1_CASE/probe" "$R1_CASE/verified.json"'], env=env)
        config = json.loads((case / 'config.json').read_text())
        assert config['nativeGlass'] and not config['interactiveGlass']
        assert config['flags'] == ['-D', 'PHOS_NATIVE_GLASS']
        configs.append((case, config))

    sdk = args.sdk[0]
    case = out/'default-sdk'; case.mkdir()
    command('default-sdk', ['/bin/sh','-eu','-c',helper],
            env=dict(environment,R1_SDK='',R1_CASE=str(case)))
    chosen = Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()).resolve()
    assert json.loads((case/'config.json').read_text())['sdk'] == str(chosen)
    case = out/'wrong-target'; case.mkdir()
    command('wrong-target', ['/bin/sh','-eu','-c',helper.replace('arm64-apple-macosx26.0','arm64-apple-macosx15.0')],
            env=dict(environment,R1_SDK=sdk,R1_CASE=str(case)),success=False)
    for label, selected, disabled in [('missing-sdk', str(out/'absent'), False),
                                      ('compile-disable', sdk, True)]:
        case = out / label; case.mkdir()
        env = dict(environment, R1_SDK=selected, R1_CASE=str(case))
        if disabled: env['PHOS_DISABLE_NATIVE_GLASS'] = '1'
        command(label, ['/bin/sh', '-eu', '-c', helper], env=env, success=False)
        assert json.loads((case/'config.json').read_text())['status'] == 'blocked'

    old_sdk = out / 'old SDK.sdk'; old_sdk.mkdir()
    (old_sdk/'SDKSettings.plist').write_bytes(plistlib.dumps({'Version':'15.4','SupportedTargets':{'macosx':{}}}))
    case = out/'old-sdk'; case.mkdir()
    command('old-sdk', ['/bin/sh','-eu','-c',helper],
            env=dict(environment,R1_SDK=str(old_sdk),R1_CASE=str(case)), success=False)

    # A compiler shim fails the real consumer's API-probe boundary, never reporting success.
    # Every entry must stop before a full compile, bundle deletion or installation.
    isolated = out / 'consumer-root'; isolated.mkdir()
    shutil.copytree(REPO/'Scripts', isolated/'Scripts')
    (isolated/'Tools').mkdir()
    shutil.copy2(REPO/'Tools/NativeGlassCompileProbe.swift', isolated/'Tools/NativeGlassCompileProbe.swift')
    shutil.copy2(REPO/'build.sh', isolated/'build.sh')
    (isolated/'Info.plist').write_bytes((REPO/'Info.plist').read_bytes())
    ref = out/'outputs/Phos-V3-test/Phos.app'; (ref/'Contents').mkdir(parents=True)
    (ref/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Reference'}))
    photo = out/'dummy.jpg'; photo.write_bytes(b'probe must block before image decoding')
    sentinel = isolated/'Phos.app'; sentinel.mkdir(); (sentinel/'keep').write_text('previous output')
    install = out/'installed-sentinel.app'; install.mkdir(); (install/'keep').write_text('installed output')
    shimdir = out/'compiler-shim'; shimdir.mkdir()
    shim = shimdir/'swiftc'
    shim.write_text('#!'+sys.executable+'\nimport json,os,sys\n'
                    'with open(os.environ["R1_TRACE"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                    'if sys.argv[1:]==["--version"]: os.execv('+repr(real_swiftc)+',['+repr(real_swiftc)+',"--version"])\n'
                    'print("injected core API probe failure")\n'
                    'sys.exit(64 if "-typecheck" in sys.argv else 65)\n')
    shim.chmod(0o755)
    consumers = [
        ('build.sh', []), ('Scripts/package_app.sh', []),
        ('Scripts/build_ui_baseline.sh', [str(out/'baseline.app'),str(ref)]),
        ('Scripts/build_visual_lab.sh', [str(out/'lab.app')]),
        ('Scripts/test_appearance.sh', [str(ref),str(out/'appearance')]),
        ('Scripts/test_studio.sh', [str(photo),str(out/'studio')]),
        ('Scripts/test_performance.sh', []),
        ('Scripts/test_real_photos.sh', [str(out/'photos'),'1',str(photo)]),
        ('Scripts/test_workflow.sh', [str(photo),str(photo)]),
    ]
    for i, (script, argv) in enumerate(consumers):
        trace = out/('consumer-'+str(i)+'.trace.jsonl')
        env = dict(environment, RF_SDK=sdk, APP_PATH=str(install), R1_TRACE=str(trace),
                   PATH=str(shimdir)+os.pathsep+environment['PATH'])
        command('consumer-'+str(i), ['/bin/bash' if script not in ['build.sh','Scripts/package_app.sh','Scripts/test_appearance.sh'] else '/bin/sh',script,*argv],
                cwd=isolated,env=env,success=False)
        calls = [json.loads(line) for line in trace.read_text().splitlines()]
        assert len(calls) == 2 and calls[0] == ['--version'] and '-typecheck' in calls[1], (script,calls)
        assert (sentinel/'keep').read_text() == 'previous output'
        assert (install/'keep').read_text() == 'installed output'

    (isolated/'Tools/NativeGlassCompileProbe.swift').unlink()
    case = out/'missing-probe'; case.mkdir()
    command('missing-probe', ['/bin/sh','-eu','-c',helper],cwd=isolated,
            env=dict(environment,R1_SDK=sdk,R1_CASE=str(case)),success=False)
    assert json.loads((case/'config.json').read_text())['reason'] == 'missing-probe-source'

    case, config = configs[0]
    for label, minimum, sdk_version in [('wrong-sdk','26.0','27.0' if config['sdkVersion']!='27.0' else '26.0'),
                                         ('wrong-minimum','15.0',config['sdkVersion'])]:
        binary = out/label
        command(label+'-create', [real_swiftc,'-parse-as-library','-sdk',config['sdk'],
                '-target','arm64-apple-macosx'+minimum,'-Xlinker','-platform_version','-Xlinker','macos',
                '-Xlinker',minimum,'-Xlinker',sdk_version,str(tiny),'-o',str(binary)])
        command(label+'-reject', [sys.executable,'Scripts/ui_build_policy.py','verify',str(binary),
                str(case/'config.json'),str(out/(label+'-verification.json'))],success=False)

    bundle = out/'signed-probe.app'; (bundle/'Contents/MacOS').mkdir(parents=True)
    shutil.copy2(case/'probe',bundle/'Contents/MacOS/Probe')
    info = dict(CFBundleExecutable='Probe',CFBundleIdentifier='com.zeno.phos.build-policy-probe',
                CFBundlePackageType='APPL',LSMinimumSystemVersion='26.0')
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    command('bundle-sign', ['codesign','--force','--sign','-',str(bundle)])
    verify_bundle = [sys.executable,'Scripts/ui_build_policy.py','verify']
    command('bundle-verify',verify_bundle+[str(bundle),str(case/'config.json'),str(out/'bundle-verification.json'),'--bundle'])
    wrong_info = out/'wrong-info.app'; shutil.copytree(bundle,wrong_info)
    (wrong_info/'Contents/Info.plist').write_bytes(plistlib.dumps({**info,'LSMinimumSystemVersion':'15.0'}))
    command('wrong-info',verify_bundle+[str(wrong_info),str(case/'config.json'),str(out/'wrong-info-verification.json'),'--bundle'],success=False)
    tampered = out/'tampered.app'; shutil.copytree(bundle,tampered)
    with (tampered/'Contents/MacOS/Probe').open('ab') as f: f.write(b'invalid-signature')
    command('wrong-signature',verify_bundle+[str(tampered),str(case/'config.json'),str(out/'wrong-signature-verification.json'),'--bundle'],success=False)
    report = dict(status='PASS',runtimeUIExecuted=False,installedAppTouched=False,
                  consumerGateCount=len(consumers),sdkConfigurations=[c for _,c in configs],cases=records)
    (out/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({'status':'PASS','cases':len(records),'consumerGates':len(consumers)},ensure_ascii=False))


if __name__ == '__main__':
    main()
