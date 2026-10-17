#!/usr/bin/env python3
"""Audit acquired rights, image/group leakage, labels and rendered targets."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image


def read(path): return json.loads(Path(path).read_text())
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(args):
    checks=[];sources=read(args.root/'sources/manifest.json')['sources'];registry={s['id']:s for s in sources}
    assert all(s['license']=='CC0-1.0' and '/publicdomain/zero/' in s['licenseUrl'] and s['releaseEligible'] is True for s in sources)
    assert all((args.root/s['evidencePath']).is_file() for s in sources)
    checks.append('Per-file CC0 rights and raw evidence retained')
    assert all(digest(args.root/s['path'])==s['sha256'] for s in sources)
    checks.append('Every source image matches acquisition SHA256')
    old={s.get('sha256') for s in read(args.baseline/'sources/manifest.json')['sources'] if s.get('status')=='downloaded'}
    assert not old & {s['sha256'] for s in sources}
    checks.append('Week-one held-out fixtures excluded from new sources')
    splits={};all_rows=[];groups={};hash_splits={}
    for split in ['train','validation','test']:
        rows=[json.loads(line) for line in (args.root/'sft'/(split+'.jsonl')).read_text().splitlines()]
        splits[split]=len(rows)
        for row in rows:
            record=read(args.root/'records'/(row['id']+'.json'));source=registry[record['sourceId']]
            assert record['groupId']==source['groupId'] and record['split']==split
            for key,table in [(record['groupId'],groups),(source['sha256'],hash_splits)]:
                assert key not in table or table[key]==split,'Cross-split leakage';table[key]=split
            assert json.loads(row['messages'][-1]['content'])==record.get('plan',record.get('crop'))
            assert row['labelType']=='synthetic_verified' and record['review']['decision']=='pending' and not record['quality']['humanAestheticApproval']
            rendering=args.root/record['renderPath'];report=read(rendering/'render.json')
            assert not report.get('directionError') and not report.get('normalizations')
            before=read(rendering/'before-params.json');after=read(rendering/'after-params.json')
            if row['task']=='edit':
                allowed=set(record['plan']['adjustments'])
                for key in ['exposure','temperature','tint','contrast','highlights','shadows','whites','blacks','grain']:
                    if key not in allowed: assert before[key]==after[key],(row['id'],key)
                if record['plan']['masks']:
                    assert len(after['masks'])==len(before['masks'])+len(record['plan']['masks'])
                if not any(record['plan'].get(k) for k in ['adjustments','masks','curves','hsl','grading']): assert before==after
            with Image.open(row['images'][0]) as image: assert max(image.size)<=336 and image.mode=='RGB'
            all_rows.append(row)
    assert len({r['id'] for r in all_rows})==len(all_rows)
    checks.extend(['Author groups and original-image hashes do not cross splits','Answers match verified executable labels','Synthetic examples are not misrepresented as human-approved aesthetics','No unintended global changes in local/advanced/no-op targets','All model inputs are bounded RGB images'])
    for dirname in ['sft-compact','smoke-compact']:
        for path in (args.root/dirname).glob('*.jsonl'):
            original=args.root/('sft' if dirname=='sft-compact' else 'smoke-data')/path.name
            left=[json.loads(x) for x in original.read_text().splitlines()];right=[json.loads(x) for x in path.read_text().splitlines()]
            assert len(left)==len(right)
            for a,b in zip(left,right): assert a['images']==b['images'] and a['messages'][-1]==b['messages'][-1] and a['groupId']==b['groupId']
    checks.append('Compact context preserves images, answers and split identity')
    report={'status':'passed','checks':checks,'photos':len(sources),'samples':len(all_rows),'splits':splits,'groups':len(groups)}
    (args.root/'data-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);main(p.parse_args())
