#!/usr/bin/env python3
"""Install a signed production bundle, retaining a verified rollback archive."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree(root):
    return {str(p.relative_to(root)): sha(p.read_bytes()) for p in sorted(root.rglob('*')) if p.is_file()}


def verify(bundle):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.zeno.phos' or info.get('PhosQABuild'):
        raise ValueError('Only the production Phos bundle can replace the local installation.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True, capture_output=True)


def install(source, destination, backup_root, report):
    source = source.resolve(strict=True)
    destination = destination.absolute()
    if source == destination or destination.is_symlink():
        raise ValueError('Use a separate candidate and a non-symlink installation path.')
    verify(source)
    expected = tree(source)
    token = uuid.uuid4().hex
    stage = destination.parent / ('.Phos-install-' + token)
    previous = destination.parent / ('.Phos-previous-' + token)
    destination.parent.mkdir(parents=True, exist_ok=True)
    archive = None
    old = {}
    try:
        subprocess.run(['ditto', str(source), str(stage)], check=True)
        verify(stage)
        if tree(stage) != expected:
            raise ValueError('Staged bundle differs from the verified candidate.')
        if destination.exists():
            old = tree(destination)
            backup_root.mkdir(parents=True, exist_ok=True)
            archive = backup_root / ('Phos-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + token[:8] + '.zip')
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(destination), str(archive)], check=True)
            with zipfile.ZipFile(archive) as saved:
                if saved.testzip() is not None:
                    raise ValueError('Rollback archive CRC failed.')
                for name, digest in old.items():
                    if sha(saved.read(destination.name + '/' + name)) != digest:
                        raise ValueError('Rollback archive content mismatch: ' + name)
            os.rename(destination, previous)
        try:
            os.rename(stage, destination)
            verify(destination)
            if tree(destination) != expected:
                raise ValueError('Installed bundle differs from the candidate.')
        except BaseException:
            if destination.exists():
                shutil.rmtree(destination)
            if previous.exists():
                os.rename(previous, destination)
            raise
        if previous.exists():
            shutil.rmtree(previous)
        result = dict(status='passed', candidate=str(source), installed=str(destination),
                      rollbackArchive=str(archive) if archive else None,
                      rollbackArchiveSHA256=sha(archive.read_bytes()) if archive else None,
                      previousFiles=old, installedFiles=expected, bundleID='com.zeno.phos',
                      runningInstanceRestarted=False)
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k not in ('previousFiles', 'installedFiles')}, ensure_ascii=False))
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--backup-root', type=Path, default=Path.home() / 'Library/Application Support/Phos/BuildBackups')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    install(args.source, args.destination, args.backup_root, args.report)
