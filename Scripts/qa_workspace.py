#!/usr/bin/env python3
"""Snapshot, build and restore an isolated Phos QA workspace; never install an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
QA_ID = 'com.zeno.phos.qa'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def run(argv, **kwargs):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, **kwargs)


def tree(path):
    return {str(p.relative_to(path)): sha(p) for p in sorted(path.rglob('*')) if p.is_file()}


def fresh(path):
    path = Path(path).expanduser().resolve()
    if path == REPO or REPO in path.parents or path == Path('/Applications') or Path('/Applications') in path.parents:
        raise ValueError('Use a new output directory outside the checkout and /Applications.')
    path.mkdir(parents=True, exist_ok=False)
    return path


def snapshot(destination, app):
    destination.mkdir(parents=True, exist_ok=False)
    names = run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=REPO).split('\0')
    names = sorted(set(n for n in names if n))
    records = {}
    with tarfile.open(destination / 'source.tar.gz', 'w:gz') as archive:
        for name in names:
            p = REPO / name
            if not p.exists():  # Deleted tracked files are represented by their absence and the patch.
                continue
            if p.is_symlink() or not p.is_file():
                raise ValueError('Snapshot requires regular project files: ' + name)
            records[name] = dict(sha256=sha(p), mode=p.stat().st_mode & 0o777)
            archive.add(p, arcname=name, recursive=False)
    (destination / 'working-tree.patch').write_bytes(subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=REPO))
    (destination / 'git-status.txt').write_text(run(['git', 'status', '--short'], cwd=REPO))
    run(['git', 'bundle', 'create', str(destination / 'history.bundle'), '--all', 'HEAD'], cwd=REPO)
    app = Path(app).resolve(strict=True)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(destination / 'installed-app.zip')])
    manifest = dict(sourceRoot=str(REPO), head=run(['git', 'rev-parse', 'HEAD'], cwd=REPO).strip(),
                    sourceFiles=records, sourceScope='tracked and non-ignored untracked regular files; excludes build caches',
                    installedAppRoot=str(app), installedAppName=app.name, installedAppFiles=tree(app),
                    archives={n: sha(destination / n) for n in ['source.tar.gz', 'working-tree.patch', 'history.bundle', 'installed-app.zip']})
    write(destination / 'snapshot.json', manifest)
    return manifest


def extract_source(snapshot_dir, destination):
    manifest = json.loads((snapshot_dir / 'snapshot.json').read_text())
    assert sha(snapshot_dir / 'source.tar.gz') == manifest['archives']['source.tar.gz']
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(snapshot_dir / 'source.tar.gz') as archive:
        members = archive.getmembers()
        assert {m.name for m in members} == set(manifest['sourceFiles'])
        for m in members:
            p = Path(m.name)
            if p.is_absolute() or '..' in p.parts or not m.isfile():
                raise ValueError('Unsafe source archive member: ' + m.name)
            target = destination / p
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(m) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            target.chmod(manifest['sourceFiles'][m.name]['mode'])
    assert tree(destination) == {p: item['sha256'] for p, item in manifest['sourceFiles'].items()}
    return manifest


def restore(args):
    source = Path(args.snapshot).resolve(strict=True)
    manifest = json.loads((source / 'snapshot.json').read_text())
    for name, expected in manifest['archives'].items():
        assert sha(source / name) == expected, name
    out = fresh(args.out)
    extract_source(source, out / 'source')
    # Restore Git history too; the extracted working tree keeps all local changes and untracked files.
    run(['git', 'init', '-q', str(out / 'source')])
    run(['git', 'fetch', str(source / 'history.bundle'), manifest['head']], cwd=out / 'source')
    run(['git', 'reset', '--mixed', manifest['head']], cwd=out / 'source')
    with zipfile.ZipFile(source / 'installed-app.zip') as archive:
        for member in archive.namelist():
            p = Path(member)
            if p.is_absolute() or '..' in p.parts:
                raise ValueError('Unsafe app archive member.')
    run(['ditto', '-x', '-k', str(source / 'installed-app.zip'), str(out / 'app-baseline')])
    app = out / 'app-baseline' / manifest['installedAppName']
    assert tree(app) == manifest['installedAppFiles']
    report = dict(status='passed', sourceFilesVerified=len(manifest['sourceFiles']),
                  appFilesVerified=len(manifest['installedAppFiles']), restoredTo=str(out),
                  originalCheckoutTouched=False, installedAppTouched=False)
    write(out / 'restore-verification.json', report)
    print(json.dumps(report, ensure_ascii=False))


def build(args):
    fixtures = Path(args.fixtures).expanduser().resolve(strict=True)
    out_path = Path(args.out).expanduser().resolve()
    if out_path == fixtures or fixtures in out_path.parents or out_path in fixtures.parents:
        raise ValueError('QA output and fixture input must be separate.')
    out = fresh(out_path)
    manifest = snapshot(out / 'baseline', args.app_baseline)
    source = out / '.work/source'
    extract_source(out / 'baseline', source)
    work = out / 'workspace'
    copies = work / 'photos/fixtures'
    copies.mkdir(parents=True)
    fixture_hashes = {}
    for p in sorted(fixtures.iterdir()):
        if p.name.startswith('.'):
            continue
        if p.is_symlink() or not p.is_file():
            raise ValueError('Fixtures must be regular files: ' + str(p))
        fixture_hashes[p.name] = sha(p)
        shutil.copy2(p, copies / p.name)
    if not fixture_hashes:
        raise ValueError('The fixture directory is empty.')
    for name in ('exports', 'settings'):
        (work / name).mkdir()
    write(out / 'fixture-manifest.json', dict(input=str(fixtures), workingCopies=str(copies), files=fixture_hashes))
    environment = dict(os.environ, PHOS_QA_BUILD_OUT=str(out))
    if args.sdk:
        environment['RF_SDK'] = args.sdk
    script = '''. ./Scripts/ui_compile_flags.sh
phos_ui_compile_flags "${RF_SDK:-}" arm64-apple-macosx26.0 "$PHOS_QA_BUILD_OUT/ui-capabilities.json"
swiftc -O -D PHOS_QA $PHOS_UI_SWIFT_FLAGS $PHOS_UI_LINK_FLAGS -sdk "$PHOS_BUILD_SDK" \
  -target "$PHOS_BUILD_TARGET" -module-cache-path "$PHOS_QA_BUILD_OUT/.work/module-cache" \
  Sources/Phos/*.swift -o "$PHOS_QA_BUILD_OUT/.work/PhosQA"
phos_verify_ui_binary "$PHOS_QA_BUILD_OUT/.work/PhosQA" "$PHOS_QA_BUILD_OUT/binary-verification.json"
'''
    with (out / 'compile.log').open('w') as log:
        subprocess.run(['/bin/sh', '-eu', '-c', script], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    stage = out / '.work/PhosQA.app'
    (stage / 'Contents/MacOS').mkdir(parents=True)
    resources = stage / 'Contents/Resources'
    resources.mkdir()
    info = plistlib.loads((source / 'Info.plist').read_bytes())
    info.update(CFBundleIdentifier=QA_ID, CFBundleName='PhosQA', CFBundleDisplayName='Phos QA',
                CFBundleExecutable='PhosQA', LSMinimumSystemVersion='26.0',
                PhosQABuild=True, PhosQAWorkspace=str(work))
    (stage / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(out / '.work/PhosQA', stage / 'Contents/MacOS/PhosQA')
    with (out / 'resources.log').open('w') as log:
        subprocess.run(['sh', 'Scripts/package_icon.sh', str(resources)], cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
    run(['codesign', '--force', '--deep', '--sign', '-', str(stage)])
    run(['python3', str(source / 'Scripts/ui_build_policy.py'), 'verify', str(stage),
         str(out / 'ui-capabilities.json'), str(out / 'bundle-verification.json'), '--bundle'])
    app = out / 'PhosQA.app'
    stage.rename(app)
    assert tree(Path(args.app_baseline).resolve()) == manifest['installedAppFiles']
    assert {n: sha(fixtures / n) for n in fixture_hashes} == fixture_hashes
    report = dict(status='passed', app=str(app), bundleID=QA_ID, compileDefines=['PHOS_QA', 'PHOS_NATIVE_GLASS'],
                  sourceSnapshot=str(out / 'baseline/snapshot.json'), sourceFiles=manifest['sourceFiles'],
                  fixtureManifest=str(out / 'fixture-manifest.json'), workspace=str(work),
                  binarySHA256=sha(app / 'Contents/MacOS/PhosQA'),
                  appFiles=tree(app), originalFixturesUnchanged=True, installedAppUnchanged=True,
                  launched=False, runtimeValidation='pending current-host editor validation')
    write(out / 'qa-build.json', report)
    print(json.dumps({k: v for k, v in report.items() if k not in ('sourceFiles', 'appFiles')}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('build')
    command.add_argument('--out', required=True)
    command.add_argument('--fixtures', default=str(REPO.parent / 'outputs/Phos-V3-evidence/S1-A/fixtures/pristine'))
    command.add_argument('--app-baseline', default='/Applications/Phos.app')
    command.add_argument('--sdk')
    command.set_defaults(handler=build)
    command = commands.add_parser('restore')
    command.add_argument('--snapshot', required=True)
    command.add_argument('--out', required=True)
    command.set_defaults(handler=restore)
    args = parser.parse_args()
    try:
        args.handler(args)
    except (ValueError, OSError, AssertionError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Phos QA operation failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
