#!/usr/bin/env python3
"""Build deterministic, task-balanced before/after sheets for label inspection."""
import argparse
import collections
import json
import random
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps


def group(record):
    if record['task']=='crop':return 'crop'
    plan=record['plan']
    if plan.get('masks'):return plan['masks'][0]['kind']
    if plan.get('curves'):return 'curves'
    if plan.get('hsl'):return 'mixed' if plan['adjustments'] else 'hsl'
    return 'whitebalance' if 'temperature' in plan['adjustments'] else 'global'


def main(root):
    root=root.resolve();out=root/'review';out.mkdir(exist_ok=True)
    groups=collections.defaultdict(list)
    for path in sorted((root/'records').glob('*-varied-*.json')):
        record=json.loads(path.read_text());groups[group(record)].append(record)
    rng=random.Random(1810);selected=[]
    for name,records in sorted(groups.items()):selected+=rng.sample(records,min(3,len(records)))
    font=ImageFont.truetype('/System/Library/Fonts/STHeiti Light.ttc',15)
    for page in range((len(selected)+7)//8):
        canvas=Image.new('RGB',(1280,1120),'#f4f4f4');draw=ImageDraw.Draw(canvas)
        for index,record in enumerate(selected[page*8:(page+1)*8]):
            x=(index%2)*640;y=(index//2)*280
            for col,filename in enumerate(('before.jpg','after.jpg')):
                with Image.open(root/record['renderPath']/filename) as image:
                    image=ImageOps.contain(image.convert('RGB'),(300,210));canvas.paste(image,(x+col*315+10,y+15))
            text=record['instruction'];lines=[text[k:k+38] for k in range(0,min(len(text),114),38)]
            draw.text((x+10,y+230),'\n'.join(lines[:3]),font=font,fill='black')
        canvas.save(out/f'sheet-{page+1}.jpg',quality=90)
    (out/'review-cases.json').write_text(json.dumps({'seed':1810,'selection':'3 per operation group','reviewer':None,'humanApproved':False,'cases':[{'id':r['id'],'group':group(r),'instruction':r['instruction']} for r in selected]},ensure_ascii=False,indent=2)+'\n')
    print(out)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,required=True);main(parser.parse_args().root)
