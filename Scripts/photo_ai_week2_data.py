#!/usr/bin/env python3
"""Acquire per-file CC0 photographs and prepare verified operation-only SFT data.

This is synthetic tool-use supervision, not expert aesthetic supervision.
The week-one test fixtures remain excluded and no human approval is invented.
"""
import argparse
import collections
import concurrent.futures
import copy
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import random
import re
import time
import urllib.parse
import urllib.request

from PIL import Image, ImageDraw, ImageOps

spec = importlib.util.spec_from_file_location('workbench', Path(__file__).with_name('photo_ai_workbench.py'))
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)


def fetch(url):
    request=urllib.request.Request(url,headers={'User-Agent':'Phos-Photo-Research/1.0 (local non-generative retouching experiment)'})
    with urllib.request.urlopen(request,timeout=45) as response:
        data=response.read(12*1024*1024+1)
    if len(data)>12*1024*1024: raise ValueError('Image too large')
    return data


def clean(value): return html.unescape(re.sub('<[^>]+>','',str(value))).strip()


def collect(args):
    assets=args.root/'assets'; assets.mkdir(parents=True,exist_ok=True)
    evidence=args.root/'sources/evidence'; evidence.mkdir(parents=True,exist_ok=True)
    manifest=args.root/'sources/manifest.json'
    acquired=w.read(manifest)['sources'] if manifest.exists() else []
    ids={x['id'] for x in acquired}; hashes={x['sha256'] for x in acquired}
    author_counts=collections.Counter(x['groupId'] for x in acquired)
    queries=['landscape photograph','portrait photograph','street city photograph','sport running photograph','night city photograph','forest mountains photograph','people outdoor photograph','beach sunset photograph','architecture building photograph','animal photograph']
    rejected=[]
    for qn,query in enumerate(queries):
        if len(acquired)>=args.count: break
        params={'action':'query','generator':'search','gsrsearch':'filetype:bitmap hastemplate:CC-zero '+query,'gsrnamespace':6,'gsrlimit':30,'prop':'imageinfo','iiprop':'url|extmetadata|size|sha1','iiurlwidth':1024,'format':'json'}
        url='https://commons.wikimedia.org/w/api.php?'+urllib.parse.urlencode(params)
        raw=fetch(url); (evidence/('search-%02d.json'%qn)).write_bytes(raw)
        pages=json.loads(raw).get('query',{}).get('pages',{})
        for page in sorted(pages.values(),key=lambda p:p.get('index',0)):
            if len(acquired)>=args.count: break
            identifier='commons-'+str(page['pageid'])
            if identifier in ids: continue
            info=page.get('imageinfo',[{}])[0]; meta=info.get('extmetadata',{})
            license_name=meta.get('LicenseShortName',{}).get('value','')
            license_url=meta.get('LicenseUrl',{}).get('value','')
            if license_name not in ('CC0','CC0 1.0') or '/publicdomain/zero/' not in license_url:
                rejected.append({'id':identifier,'reason':'not-explicit-file-CC0','license':license_name}); continue
            author=clean(meta.get('Artist',{}).get('value',''))
            if not author: continue
            categories=clean(meta.get('Categories',{}).get('value','')).lower()
            if any(term in categories for term in ('paintings','engravings','prints in','drawings','black and white photographs','black-and-white photographs','photographic reproductions')):
                rejected.append({'id':identifier,'reason':'artwork-or-monochrome-category'});continue
            group='author-'+hashlib.sha256(author.casefold().encode()).hexdigest()[:12]
            if author_counts[group]>=3: continue
            if info.get('width',0)<500 or info.get('height',0)<350: continue
            image_url=info.get('thumburl',info.get('url','')).split('?')[0]
            if not image_url.startswith('https://') or not urllib.parse.urlsplit(image_url).hostname.endswith('wikimedia.org'): continue
            path=assets/(identifier+Path(urllib.parse.urlsplit(image_url).path).suffix.lower())
            try:
                content=fetch(image_url); path.write_bytes(content)
                with Image.open(path) as image:
                    image.load(); width,height=image.size
                    if width<300 or height<250 or max(width,height)/min(width,height)>2.5: raise ValueError('Unsuitable dimensions')
                    if image.mode not in ('RGB','RGBA'): raise ValueError('Not a color photograph')
                    # Nearby visual duplicates are not useful for a small first batch.
                    small=ImageOps.grayscale(image).resize((9,8))
                    px=list(small.getdata()); perceptual=''.join('1' if px[y*9+x]>px[y*9+x+1] else '0' for y in range(8) for x in range(8))
                digest=w.sha(path)
                if digest in hashes or any(sum(a!=b for a,b in zip(perceptual,s['dHash']))<6 for s in acquired): raise ValueError('Duplicate or near-duplicate')
                entry={'id':identifier,'kind':'photo','status':'downloaded','name':page['title'],'query':query,'path':str(path.relative_to(args.root)),'sha256':digest,'dHash':perceptual,'bytes':len(content),'dimensions':[width,height],'url':image_url,'originalUrl':info.get('url',''),'license':'CC0-1.0','licenseEvidence':info['descriptionurl'],'licenseUrl':license_url,'credit':author,'groupId':group,'releaseEligible':True,'researchEligible':True,'fetchedAt':w.now(),'evidencePath':str((evidence/('file-'+identifier+'.json')).relative_to(args.root))}
                w.write(evidence/('file-'+identifier+'.json'),page)
                acquired.append(entry); ids.add(identifier);hashes.add(digest);author_counts[group]+=1
                w.write(manifest,{'createdAt':w.now(),'sources':acquired,'rejected':rejected,'note':'Per-file CC0 verified from Wikimedia Commons imageinfo. Source photos are not expert-retouched targets. Split by author and perceptual deduplication.'})
                print('ACQUIRED',len(acquired),identifier,width,height,license_name,flush=True)
            except Exception as error:
                rejected.append({'id':identifier,'reason':str(error)})
        time.sleep(.4)
    w.write(manifest,{'createdAt':w.now(),'sources':acquired,'rejected':rejected,'note':'Per-file CC0 verified; no restricted retouching dataset used.'})
    if len(acquired)<30: raise ValueError('Insufficient distinct sources; keep partial collection and inspect failures')
    print('COLLECTED',len(acquired),'photos across',len(author_counts),'author groups',flush=True)
    contact_sheets(args,acquired)


def contact_sheets(args,sources):
    for old in (args.root/'sources').glob('contact-*.jpg'):
        if int(old.stem.split('-')[-1])*16>=len(sources):
            archive=old.parent/'excluded';archive.mkdir(exist_ok=True);old.replace(archive/('previous-'+old.name))
    for batch in range(0,len(sources),16):
        canvas=Image.new('RGB',(1200,1000),'#f0f1eb'); draw=ImageDraw.Draw(canvas)
        for index,source in enumerate(sources[batch:batch+16]):
            x=(index%4)*300;y=(index//4)*250
            with Image.open(args.root/source['path']) as image:
                image=ImageOps.contain(image.convert('RGB'),(288,215));canvas.paste(image,(x+(300-image.width)//2,y))
            draw.text((x+8,y+220),source['id'],fill='#222222')
        target=args.root/'sources'/('contact-%02d.jpg'%(batch//16));canvas.save(target,quality=90)


def templates(index):
    exposure=[-.35,-.2,.2,.35][index%4]
    direction='提亮' if exposure>0 else '压暗'
    y=[.46,.48,.53,.55][index%4]
    hue=[200,210,220,230][index%4]; sat=[5,6,8,10][index%4]
    local=[-.35,-.25,.25,.35][index%4]
    intent='brighten' if local>0 else 'darken'
    plan=lambda summary,**kw:dict(summary=summary,adjustments=kw.pop('adjustments',{}),masks=kw.pop('masks',[]),**kw)
    return [
      ('edit','只将整体曝光设置为 %s EV，其他参数保持不变，不要新增蒙版。'%exposure,plan('按要求调整整体曝光。',adjustments={'exposure':exposure})),
      ('edit','只创建亮度范围蒙版%s亮区，局部曝光 %s EV；全局曝光、白平衡和其他参数保持不变。'%('提亮' if local>0 else '压暗',local),plan('仅调整亮区。',masks=[{'kind':'luminanceRange','target':'highlights','brightness':intent,'inverted':False,'geometry':{'lumLow':.65,'lumHigh':1,'lumSoft':.15},'adjustments':{'exposure':local}}])),
      ('edit','只创建亮度范围蒙版%s暗部，局部曝光 %s EV；全局参数保持不变。'%('提亮' if local>0 else '压暗',local),plan('仅调整暗部。',masks=[{'kind':'luminanceRange','target':'shadows','brightness':intent,'inverted':False,'geometry':{'lumLow':0,'lumHigh':.35,'lumSoft':.15},'adjustments':{'exposure':local}}])),
      ('edit','只调整亮度曲线中间调，控制点设为 (0,0)、(0.25,0.25)、(0.5,%s)、(0.75,0.75)、(1,1)。其他参数保持不变，不要新增蒙版。'%y,plan('调整指定亮度曲线。',curves={'luma':[[0,0],[.25,.25],[.5,y],[.75,.75],[1,1]]})),
      ('edit','只设置阴影颜色分级：色相%s度、饱和度%s，其他参数保持不变，不要新增蒙版。'%(hue,sat),plan('设置指定阴影分级。',grading={'shadows':{'hue':hue,'sat':sat}})),
      ('edit','只用 HSL 将蓝色饱和度设置为 -15，保持曲线不变；全局参数保持不变，不要新增蒙版。',plan('仅降低蓝色饱和度。',hsl={'blue':{'sat':-15}})),
      ('crop','保留完整原构图，不要裁切，不要旋转。',{'x':0,'y':0,'width':1,'height':1}),
      ('crop','仅裁去左右各5%，保留完整高度，不要旋转。',{'x':.05,'y':0,'width':.9,'height':1}),
      ('edit','保持当前照片全部参数不变，不做任何调整，不要新增蒙版。',plan('保持当前效果。')),
      ('edit','只创建径向蒙版，圆心为归一化坐标 (0.5,0.5)，短边半径0.3，选区曝光增加0.2 EV，其他参数保持不变。',plan('仅提亮中央径向选区。',masks=[{'kind':'radial','target':'region','brightness':'brighten','inverted':False,'geometry':{'x0':.5,'y0':.5,'radiusX':.3,'radiusY':.3,'feather':.6},'adjustments':{'exposure':.2}}]))]


def prepare(args):
    sources=w.read(args.root/'sources/manifest.json')['sources']
    old_hashes={s.get('sha256') for s in w.read(args.baseline/'sources/manifest.json')['sources'] if s.get('status')=='downloaded'}
    if any(s['sha256'] in old_hashes for s in sources): raise ValueError('Week-one held-out image found in candidate training sources')
    if any(w.sha(args.root/s['path'])!=s['sha256'] for s in sources): raise ValueError('Source hash changed after acquisition')
    groups=sorted({s['groupId'] for s in sources});random.Random(1702).shuffle(groups)
    n=max(2,round(len(groups)*.12)); split={g:('test' if i<n else 'validation' if i<2*n else 'train') for i,g in enumerate(groups)}
    defaults=w.read(args.baseline/'baseline/frozen/protocol/defaults.json')
    jobs=[]
    for index,source in enumerate(sources):
        for op,(task,instruction,target) in enumerate(templates(index)):
            base=copy.deepcopy(defaults)
            if index%3==1: base['exposure']=.4;base['grain']=12
            record={'version':w.VERSION,'id':source['id']+'-%02d'%op,'sourceId':source['id'],'groupId':source['groupId'],'split':split[source['groupId']],'task':task,'instruction':instruction,'baseParams':base,'crop' if task=='crop' else 'plan':target,'review':{'decision':'pending','notes':'Synthetic tool-use example; no human aesthetic approval'},'provenance':'known Phos operation; synthetic_verified labels only; no expert aesthetic claim','labelType':'deterministic-operation','inputImage':str((args.root/source['path']).resolve())}
            jobs.append(record)
    def process(record):
        try:
            destination=args.root/'renders'/record['id']
            cached_request=w.read(destination/'request.json') if (destination/'request.json').exists() else None
            if not (destination/'render.json').exists() or cached_request!=record:
                w.worker(args,'protocol',record,destination/'protocol')
                import jsonschema
                jsonschema.validate(record.get('plan',record.get('crop')),w.read(destination/'protocol'/('crop-schema.json' if record['task']=='crop' else 'edit-schema.json')))
                w.worker(args,'render',record,destination)
            report=w.read(destination/'render.json')
            if report.get('normalizations') or report.get('directionError'): raise ValueError('Invalid direction or normalization needed')
            if record['task']=='edit' and not report['changed'] and any(record['plan'].get(key) for key in ['adjustments','masks','curves','hsl','grading']): raise ValueError('Expected edit has no parameter effect')
            # Train at a reduced, aspect-preserving image size, with the same color processing.
            with Image.open(destination/'before.jpg') as image:
                image=ImageOps.contain(image.convert('RGB'),(336,336)); image.save(destination/'model-input.jpg',quality=95)
            record['renderPath']=str(destination.relative_to(args.root));record['imageSHA256']=next(s['sha256'] for s in sources if s['id']==record['sourceId'])
            record['quality']={'status':'synthetic_verified','schema':True,'rendered':True,'directionChecked':report['directionChecked'],'humanAestheticApproval':False}
            w.write(args.root/'records'/(record['id']+'.json'),record)
            return record,None
        except Exception as error: return None,{'id':record['id'],'error':getattr(error,'message',str(error))[:1600]}
    accepted=[]; rejected=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        for record,error in executor.map(process,jobs):
            if record: accepted.append(record)
            else: rejected.append(error)
            if (len(accepted)+len(rejected))%20==0:print('PREPARED',len(accepted),'rejected',len(rejected),flush=True)
    by_split=collections.defaultdict(list)
    for record in accepted:
        destination=args.root/record['renderPath']; base=w.read(destination/'before-params.json')
        prompt=w.prompt_from_frozen(args.baseline,record,base)
        target=record.get('plan',record.get('crop'))
        by_split[record['split']].append({'id':record['id'],'images':[str((destination/'model-input.jpg').resolve())],'messages':[{'role':'user','content':prompt},{'role':'assistant','content':json.dumps(target,ensure_ascii=False,separators=(',',':'))}],'task':record['task'],'groupId':record['groupId'],'labelType':'synthetic_verified'})
    for name,rows in by_split.items():
        dest=args.root/'sft'/ (name+'.jsonl');dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    # Small fitting set is explicitly drawn only from training groups.
    sample=by_split['train'][:16]
    small=args.root/'smoke-data';small.mkdir(exist_ok=True)
    for name,rows in [('train',sample),('validation',by_split['validation'][:8])]:
        (small/(name+'.jsonl')).write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    for directory,destname in [('sft','sft-compact'),('smoke-data','smoke-compact')]:
        for source in (args.root/directory).glob('*.jsonl'):
            compact=[]
            for line in source.read_text().splitlines():
                row=json.loads(line)
                if row['task']=='edit':
                    prefix,rest=row['messages'][0]['content'].split('Current complete Phos parameters: ',1)
                    context,instruction=rest.split('\nUser request: ',1)
                    nondefaults={k:v for k,v in json.loads(context).items() if v!=defaults.get(k)}
                    row['messages'][0]['content']=prefix+'Current Phos parameters: defaults except '+json.dumps(nondefaults,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'. Omitted current parameters retain their default values.\nUser request: '+instruction
                row['promptVariant']='full-tool-rules-compact-nondefault-state';compact.append(row)
            destination=args.root/destname/source.name;destination.parent.mkdir(exist_ok=True)
            destination.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in compact))
    groups_by_split={name:sorted({r['groupId'] for r in rows}) for name,rows in by_split.items()}
    for a,b in [('train','validation'),('train','test'),('validation','test')]: assert not set(groups_by_split[a])&set(groups_by_split[b])
    report={'createdAt':w.now(),'photos':len(sources),'groups':len(groups),'accepted':len(accepted),'counts':{name:len(rows) for name,rows in by_split.items()},'groupSplits':groups_by_split,'rejected':rejected,'trainingLabelPolicy':'Only explicit known operations after schema+production rendering+direction checks. No human approval or professional taste claimed. Isolated experiment, not release export.','weekOneFixturesUsedForTraining':False}
    w.write(args.root/'dataset-report.json',report);print(json.dumps(report,ensure_ascii=False)[:2000],flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('command',choices=['collect','prepare']);p.add_argument('--root',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--worker',type=Path,required=True);p.add_argument('--count',type=int,default=48)
    args=p.parse_args();args.root=args.root.resolve();args.baseline=args.baseline.resolve();args.worker=args.worker.resolve();args.root.mkdir(parents=True,exist_ok=True)
    globals()[args.command](args)
