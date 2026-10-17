#!/usr/bin/env python3
"""Verify S0 originals, fixtures and native screenshot geometry without image dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise SystemExit('FAIL: ' + message)


def dimensions(path):
    data = path.read_bytes()
    if data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR':
        require(path.suffix.lower() == '.png', 'PNG extension mismatch')
        return struct.unpack('>II', data[16:24])
    require(data[:2] == b'\xff\xd8' and path.suffix.lower() in ['.jpg','.jpeg'], 'Invalid image or extension mismatch: ' + str(path))
    index = 2
    while index < len(data):
        require(data[index] == 255, 'Malformed JPEG marker')
        while data[index] == 255:
            index += 1
        marker = data[index]
        index += 1
        length = struct.unpack('>H',data[index:index+2])[0]
        if marker in [0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF]:
            height, width = struct.unpack('>HH',data[index+3:index+7])
            return width, height
        index += length
    raise SystemExit('FAIL: JPEG dimensions missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    root = args.evidence.resolve()
    catalog = json.loads((root/'fixtures/catalog.json').read_text())
    fixtures = {}
    for item in catalog['items']:
        for name in ['pristine', 'work']:
            path = root/'fixtures'/name/item['name']
            require(sha(path) == item['sha256'], f'{name} fixture changed: {path}')
        if item['source'].startswith('/'):
            require(sha(Path(item['source'])) == item['sourceSHA256'], 'Original changed: ' + item['source'])
        fixtures[item['name']] = item
    initial = json.loads((root/'initial/manifest.json').read_text())
    for entry in initial['app']['files']:
        for app_path in [initial['app']['originalPath'], initial['app']['backupPath']]:
            require(sha(Path(app_path)/entry['path']) == entry['sha256'], 'Original App changed: ' + app_path)
    shots = []
    paths = list((root/'screenshots').glob('*.png.json')) + list((root/'screenshots').glob('*.jpg.json'))
    for path in sorted(paths):
        info = json.loads(path.read_text())
        image = Path(str(path)[:-5])
        require(image.is_file(), 'Screenshot missing: ' + str(image))
        width, height = dimensions(image)
        requested, actual = info['requestedContentPt'], info['contentBoundsPt']
        require(all(abs(requested[key]-actual[key]) < 0.5 for key in ['width', 'height']), 'Content size mismatch: ' + str(image))
        frame, scale = info['windowFramePt'], info['backingScale']
        require(abs(width-frame['width']*scale) <= 2 and abs(height-frame['height']*scale) <= 2,
                'Screenshot does not cover the real native window: ' + str(image))
        require(info['screenshotPixels'] == dict(width=width,height=height), 'Pixel metadata mismatch')
        require(info['bundleID'] == 'com.zeno.phos.baseline' and info['applicationIsActive'], 'Wrong or inactive App')
        require(info['photo'] in fixtures and info['photoID'], 'Unknown fixture/photo identity')
        require(info['previewPixels']['width'] > 0 and info['previewPixels']['height'] > 0, 'Empty preview')
        shots.append(dict(name=image.stem,path=str(image),metadata=str(path),photo=info['photo'],
                          appearance=info['appearance'],contentPt=requested,pixels=dict(width=width,height=height),
                          backingScale=scale,windowID=info['windowID'],processID=info['processID'],sha256=sha(image)))
    names = {s['name'] for s in shots}
    canonical = {f'studio-{size}-{theme}-landscape'
                 for size in ['1100x700','1440x900','1680x1050'] for theme in ['light','dark']}
    require(canonical <= names, 'Six canonical screenshots are incomplete')
    require(set(fixtures) <= {s['photo'] for s in shots}, 'Some fixtures lack screenshots')
    result = dict(status='PASS',originalAppAndBackupUnchanged=True,fixtureImagesVerified=len(fixtures),
                  canonicalScreenshotsVerified=6,screenshotsVerified=len(shots),screenshots=shots)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(f'PASS: {len(fixtures)} fixtures/originals, 6 canonical screenshots, {len(shots)} native screenshots, original App/backup')


if __name__ == '__main__':
    main()
