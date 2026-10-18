#!/usr/bin/env python3
"""Versioned P0/P1 tools. No training, no aesthetic approval inferred."""
import argparse, collections, concurrent.futures, copy, hashlib, importlib.util, json, random, re, shutil, subprocess, time, urllib.parse, urllib.request
from pathlib import Path
from PIL import Image, ImageOps, ImageDraw
from photo_ai_protocol import serialize_target
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('week2',HERE/'photo_ai_week2_data.py');d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)
w=d.w

def fetch(url,limit=16*1024**2):
    for attempt in range(3):
        try:
            url=urllib.parse.quote(url,safe=':/?&=%#');req=urllib.request.Request(url,headers={'User-Agent':'Phos-Photo-Research/1.0 (local non-generative retouching experiment)'})
            with urllib.request.urlopen(req,timeout=25) as response:data=response.read(limit+1)
            if len(data)>limit:raise ValueError('download size limit')
            return data
        except Exception:
            if attempt==2:raise
            time.sleep(1+attempt)

def collect(a):
    root=a.root;out=root/'sources';(out/'evidence').mkdir(parents=True,exist_ok=True);(root/'assets').mkdir(exist_ok=True)
    prior=w.read(a.legacy/'sources/manifest.json')['sources'];old_ids={x['id'] for x in prior}
    candidates={};queries=['landscape','portrait','street','sport running','night city','forest mountain','people outdoor','beach sunset','architecture','animal','interior','backlit','food','snow','concert','bird','cycling','train','rain street','flower','desert','waterfall','window light','market','festival','school sport','urban park','sunrise','bridge','dog','cat','coast','hiking','stadium','cafe','museum interior','forest autumn','underwater','football','basketball']
    queries += ['hiking people','runners race','fashion portrait','indoor people','festival people','backlit portrait','street portrait','sports field','basketball game','face person']
    errors=[]
    for i,query in enumerate(queries):
        cache=out/'evidence'/('search-%02d.json'%i)
        try:
            if not cache.exists():
                params={'action':'query','generator':'search','gsrsearch':'filetype:bitmap hastemplate:CC-zero '+query+' photograph','gsrnamespace':6,'gsrlimit':50,'prop':'imageinfo','iiprop':'url|extmetadata|size|sha1','iiurlwidth':1024,'format':'json'}
                cache.write_bytes(fetch('https://commons.wikimedia.org/w/api.php?'+urllib.parse.urlencode(params)))
            pages=w.read(cache).get('query',{}).get('pages',{})
            for page in pages.values():
                identifier='commons-'+str(page['pageid'])
                if identifier in old_ids:continue
                info=page.get('imageinfo',[{}])[0];meta=info.get('extmetadata',{});lic=meta.get('LicenseShortName',{}).get('value','');license_url=meta.get('LicenseUrl',{}).get('value','')
                author=d.clean(meta.get('Artist',{}).get('value',''));cats=d.clean(meta.get('Categories',{}).get('value','')).lower()
                if lic not in ('CC0','CC0 1.0') or '/publicdomain/zero/' not in license_url or not author:continue
                if any(x in cats for x in ('paintings','engravings','drawings','photographic reproductions','black and white photographs','black-and-white photographs')):continue
                if min(info.get('width',0),info.get('height',0))<400:continue
                url=info.get('thumburl',info.get('url','')).split('?')[0]
                if urllib.parse.urlsplit(url).hostname not in ('upload.wikimedia.org','thumb.wikimedia.org','commons.wikimedia.org'):continue
                candidates.setdefault(identifier,(page,query))
            print('SEARCH',i,len(candidates),flush=True)
        except Exception as e:errors.append({'query':query,'error':str(e)})
    existing=w.read(out/'manifest.json')['sources'] if (out/'manifest.json').exists() else []
    ids={s['id'] for s in existing};hashes={s['sha256'] for s in existing};groups=collections.Counter(s['groupId'] for s in existing)
    dhashes=[s['dHash'] for s in existing]+[s['dHash'] for s in prior]
    def acquire(item):
        identifier,(page,query)=item;info=page['imageinfo'][0];meta=info['extmetadata'];author=d.clean(meta['Artist']['value']);group='author-'+hashlib.sha256(author.casefold().encode()).hexdigest()[:12]
        if identifier in ids or groups[group]>=7:return None
        url=info.get('thumburl',info['url']).split('?')[0];url=url.replace('/1024px-','/960px-');path=root/'assets'/(identifier+Path(urllib.parse.urlsplit(url).path).suffix.lower())
        try:
            if not path.exists():path.write_bytes(fetch(url))
            with Image.open(path) as im:
                im.load();width,height=im.size
                if im.mode not in ('RGB','RGBA') or min(width,height)<300 or max(width,height)/min(width,height)>2.6:raise ValueError('unsupported dimensions/color')
                small=ImageOps.grayscale(im).resize((9,8));px=list(small.getdata());dh=''.join('1' if px[y*9+x]>px[y*9+x+1] else '0' for y in range(8) for x in range(8))
            return {'id':identifier,'path':str(path.relative_to(root)),'kind':'photo','status':'downloaded','name':page['title'],'query':query,'sha256':w.sha(path),'dHash':dh,'bytes':path.stat().st_size,'dimensions':[width,height],'url':url,'originalUrl':info['url'],'license':'CC0-1.0','licenseEvidence':info['descriptionurl'],'licenseUrl':meta['LicenseUrl']['value'],'credit':author,'groupId':group,'researchEligible':True,'releaseEligible':True,'fetchedAt':w.now(),'visualReview':'pending-contact-sheet','evidencePath':'sources/evidence/file-'+identifier+'.json'},page
        except Exception as e:return {'error':str(e),'id':identifier},None
    items=[x for x in candidates.items() if x[0] not in ids]
    # Bound requests by chunk, rather than scheduling hundreds after enough photos exist.
    for offset in range(0,len(items),24):
        if len(existing)>=a.count:break
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
            for result in ex.map(acquire,items[offset:offset+24]):
                if result is None:continue
                source,page=result
                if 'error' in source:errors.append(source);continue
                if len(existing)>=a.count:continue
                if source['sha256'] in hashes or groups[source['groupId']]>=7 or any(sum(x!=y for x,y in zip(source['dHash'],dh))<6 for dh in dhashes):continue
                existing.append(source);ids.add(source['id']);hashes.add(source['sha256']);dhashes.append(source['dHash']);groups[source['groupId']]+=1
                w.write(root/source['evidencePath'],page)
        w.write(out/'manifest.json',{'sources':existing,'errors':errors,'createdAt':w.now(),'requestedPhotos':a.count,'legacyIdsExcluded':True,'policy':'Per-file CC0 metadata; visual suitability review pending; not expert retouching.'})
        print('COLLECTED',len(existing),'groups',len(groups),flush=True)
    d.contact_sheets(a,existing)
    if len(existing)<a.count:raise RuntimeError('Collection incomplete: %d/%d; see manifest errors'%(len(existing),a.count))

def protocol(a):
    out=a.root/'protocol';w.worker(a,'protocol',{'instruction':'','task':'edit'},out)
    base=w.read(out/'defaults.json');reg=w.read(out/'parameter-registry.json')
    model=Path.home()/'Library/Application Support/Phos/MLX/model';adapter=Path('/Applications/Phos.app/Contents/Resources/PhotoAIAdapter');adapter=adapter if adapter.exists() else Path.home()/'Library/Application Support/Phos/MLX/adapter';bm=w.read(a.root/'baseline/frozen/manifest.json')
    fingerprint={'baseRepo':w.read(adapter/'manifest.json')['baseRepo'],'baseRevision':w.read(adapter/'manifest.json')['baseRevision'],'baseFiles':bm['modelFiles'],'quantization':w.read(model/'config.json')['quantization'],'adapterPath':str(adapter),'adapterFiles':{p.name:w.sha(p) for p in adapter.iterdir() if p.is_file()},'schemaVersion':reg['version'],'workerSHA256':w.sha(a.worker),'installedBinarySHA256':w.sha(Path('/Applications/Phos.app/Contents/MacOS/Phos')),'promptSHA256':w.sha(out/'prompt.txt')}
    w.write(a.root/'baseline/model-fingerprint.json',fingerprint)
    shutil.copytree(adapter,a.root/'baseline/incumbent-adapter',dirs_exist_ok=True)
    files={str(p.relative_to(w.REPO)):w.sha(p) for directory in ('Sources/Phos','Scripts','Tools') for p in (w.REPO/directory).rglob('*') if p.is_file() and p.suffix in ('.swift','.py','.sh')}
    w.write(out/'toolchain-files.json',files)
    envelope={'schemaVersion':reg['version'],'protectedFields':'host-supplied existing parameter paths, immutable','baseStateId':'SHA256 of canonical baseParams JSON','operationId':'unique request ID; retries grouped under same ID','confidence':'uncalibrated/unavailable until validation calibration; not synthesized as ground truth','retryBudget':1,'reportFields':['firstAttemptSuccess','postRetrySuccess','schemaValid','rawDirectionCorrect','protectedViolation','refused','renderedSuccess','seconds'],'nonGoals':['automatic retry deduplication not implemented in production','no aesthetic approval inferred','no model training in P0/P1']}
    w.write(out/'request-contract.json',envelope)
    print('PROTOCOL',len(reg['parameters']),'numeric descriptors',flush=True)

def templates(index):
    tasks=d.templates(index)
    value=[-.3,-.15,.15,.3][index%4];intent='brighten' if value>0 else 'darken';verb='提亮' if value>0 else '压暗'
    plan=lambda **kw:dict(summary='执行指定操作。',adjustments=kw.pop('adjustments',{}),masks=kw.pop('masks',[]),**kw)
    tasks += [('edit','只用线性渐变蒙版%s选区，起点(0.2,0.8)，终点(0.8,0.2)，羽化0.5，局部曝光设置为%s EV；全局参数保持不变。'%(verb,value),plan(masks=[{'kind':'linear','target':'region','brightness':intent,'geometry':{'x0':.2,'y0':.8,'x1':.8,'y1':.2,'feather':.5},'adjustments':{'exposure':value}}])),('edit','整体曝光设置为%s EV，同时把对比度设置为8。其他参数保持不变，不要新增蒙版。'%value,plan(adjustments={'exposure':value,'contrast':8})),('edit','只把颗粒设置为12、暗角设置为-8；不要修改白平衡，不要新增蒙版。',plan(adjustments={'grain':12,'vignette':-8})),('edit','保持白平衡和曲线不变，只把鲜艳度设置为10，不要新增蒙版。',plan(adjustments={'vibrance':10}))]
    return tasks

def prepare(a):
    import jsonschema  # fail before creating any records if tooling dependencies are missing
    if any(w.read(p).get('review',{}).get('decision')=='approved' for p in (a.root/'records').glob('*.json')):raise ValueError('Human-approved records exist; use a fresh versioned dataset root')
    sources=w.read(a.root/'sources/manifest.json')['sources'];reviews=w.read(a.root/'sources/visual-review.json') if (a.root/'sources/visual-review.json').exists() else {}
    excluded=set(reviews.get('excludedIds',[]));sources=[s for s in sources if s['id'] not in excluded]
    if reviews.get('status')!='reviewed':raise ValueError('Contact sheet review must be recorded before dataset export')
    prior=w.read(a.legacy/'sources/manifest.json')['sources'];seen_groups={s['groupId'] for s in prior}
    groups=sorted({s['groupId'] for s in sources});random.Random(1810).shuffle(groups)
    # Legacy-seen authors can only contribute training, never fresh validation/test/vision.
    fresh=[g for g in groups if g not in seen_groups];split={};counts=collections.Counter()
    for name,target in [('vision',45),('test',60),('validation',60)]:
        for g in fresh:
            if g in split:continue
            split[g]=name;counts[name]+=sum(s['groupId']==g for s in sources)
            if counts[name]>=target:break
    for g in groups:split.setdefault(g,'train')
    w.write(a.root/'split-manifest.json',{'seed':1810,'groups':split,'photos':dict(collections.Counter(split[s['groupId']] for s in sources)),'legacyAuthorGroupsForbiddenFromFreshEvaluation':sorted(seen_groups),'sourceManifestSHA256':w.sha(a.root/'sources/manifest.json')})
    defaults=w.read(a.root/'protocol/defaults.json');jobs=[]
    for i,source in enumerate(sources):
        name=split[source['groupId']]
        if name=='vision':continue
        all_tasks=templates(i)
        if source['id'] in set(reviews.get('visiblePeopleIds',[])):
            local = .25 if i%2 else -.25
            intent = 'brighten' if local>0 else 'darken'
            verb = '提亮' if local>0 else '压暗'
            for target in ('subject','background'):
                instruction='只创建人物蒙版%s%s，局部曝光设置为%s EV；全局参数保持不变。'%(verb,'人物' if target=='subject' else '背景',local)
                all_tasks.append(('edit',instruction,{'summary':'只调整指定语义区域。','adjustments':{},'masks':[{'kind':'person','target':target,'brightness':intent,'inverted':target=='background','adjustments':{'exposure':local}}]}))
        choices=sorted({(i*5+j)%len(all_tasks) for j in range(10)}) if name=='train' else [0,1+(i%2),6+(i%2),[3,4,5,9,10,11,12,13][i%8]]
        if len(all_tasks)>14:choices=sorted(set(choices+[14,15]))
        for n in choices:
            task,instruction,target=all_tasks[n];base=copy.deepcopy(defaults)
            if i%3==1:base['exposure']=.4;base['grain']=7
            if i%5==2:base['temperature']=-8;base['tint']=3
            if i%7==3:
                seed_masks=sorted((a.legacy/'renders').glob('*/after-params.json'))
                for seed in seed_masks:
                    values=w.read(seed).get('masks',[])
                    if values:
                        base['masks']=[copy.deepcopy(values[0])];base['masks'][0]['id']='00000000-0000-4000-8000-000000000181';break
            # Equivalent paraphrases preserve numbers and negation verbatim.
            prefixes=['','请按以下明确要求编辑：','这次编辑只执行这些要求：','请准确应用下面的设置：','本次修图要求如下：','请生成符合这些条件的参数：','请按指定数值和范围操作：','请保留未提到的编辑，执行：']
            instruction=prefixes[(i+n)%len(prefixes)]+instruction
            record={'version':'phos-dataset-v2','id':source['id']+'-%02d'%n,'sourceId':source['id'],'groupId':source['groupId'],'split':name,'task':task,'instruction':instruction,'baseParams':base,'inputImage':str((a.root/source['path']).resolve()),'crop' if task=='crop' else 'plan':target,'labelType':'controlled-operation','review':{'decision':'pending','notes':'No human aesthetic approval'},'provenance':'known operation rendered by production Phos engine','schemaVersion':'phos-parameter-plan-v2','protectedFields':['temperature','tint'] if n in (12,13) else [],'confidence':None}
            if task=='edit':
                allowed=set(target.get('adjustments',{}))
                allowed.update({'rgb':'curve','luma':'lumaCurve','red':'curveR','green':'curveG','blue':'curveB'}[k] for k in target.get('curves',{}))
                allowed.update({'shadows':'gradeShadow','midtones':'gradeMid','highlights':'gradeHigh'}[k] for k in target.get('grading',{}))
                if target.get('hsl'):allowed.add('hsl')
                record['protectedFields']=sorted(set(base)-allowed-{'masks'})
            record['baseStateId']=hashlib.sha256(json.dumps(base,sort_keys=True,separators=(',',':')).encode()).hexdigest();record['operationId']=record['id'];jobs.append(record)
    bysplit=collections.defaultdict(list);rejected=[];accepted=[]
    def process(record):
        dest=a.root/'renders'/record['id']
        try:
            if not (dest/'render.json').exists() or w.read(dest/'request.json')!=record:
                if not (dest/'protocol/prompt.txt').exists() or w.read(dest/'protocol/request.json')!=record:
                    w.worker(a,'protocol',record,dest/'protocol')
                import jsonschema
                jsonschema.Draft202012Validator(w.read(dest/'protocol'/('crop-schema.json' if record['task']=='crop' else 'edit-schema.json'))).validate(record.get('plan',record.get('crop')))
                w.worker(a,'render',record,dest)
            report=w.read(dest/'render.json')
            if report.get('normalizations') or report.get('directionError') or report.get('rawDirectionError'):raise ValueError('raw/canonical direction or normalization failure')
            before=w.read(dest/'before-params.json');after=w.read(dest/'after-params.json')
            if any(before[k]!=after[k] for k in record['protectedFields']):raise ValueError('protected field changed')
            with Image.open(dest/'before.jpg') as im:ImageOps.contain(im.convert('RGB'),(336,336)).save(dest/'model-input.jpg',quality=95)
            record.update(renderPath=str(dest.relative_to(a.root)),imageSHA256=w.sha(Path(record['inputImage'])),quality={'status':'synthetic_verified','humanAestheticApproval':False,'rawDirectionCorrect':True,'protectedFieldsUnchanged':True})
            w.write(a.root/'records'/(record['id']+'.json'),record)
            row={'id':record['id'],'images':[str((dest/'model-input.jpg').resolve())],'messages':[{'role':'user','content':(dest/'protocol/prompt.txt').read_text()},{'role':'assistant','content':serialize_target(record.get('plan',record.get('crop')))}],'task':record['task'],'groupId':record['groupId'],'sourceId':record['sourceId'],'promptVariant':'production-shared-builder-v2','labelType':'synthetic_verified'}
            return record,row,None
        except Exception as e:return record,None,{'id':record['id'],'error':str(e)[:1000]}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        for i,(record,row,error) in enumerate(ex.map(process,jobs)):
            if error:rejected.append(error)
            else:accepted.append(record);bysplit[record['split']].append(row)
            if i%50==0:print('PREPARED',i+1,'rejected',len(rejected),flush=True)
    for name,rows in bysplit.items():
        path=a.root/'sft'/(name+'.jsonl');path.parent.mkdir(exist_ok=True);path.write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in rows))
    vision=[s for s in sources if split[s['groupId']]=='vision'];w.write(a.root/'vision-reserve.json',{'sources':vision,'annotationStatus':'scene/grounding annotations pending; not an accuracy benchmark yet','neverUsedForTraining':True})
    manifest=[]
    for source in sources:
        manifest.append(dict(source,split=split[source['groupId']],visualReview='contact-sheet-reviewed',humanAestheticApproval=False))
    (a.root/'dataset_manifest.jsonl').write_text(''.join(json.dumps(s,ensure_ascii=False)+'\n' for s in manifest))
    w.write(a.root/'dataset-report.json',{'photos':len(sources),'groups':len(groups),'records':len(accepted),'counts':{k:len(v) for k,v in bysplit.items()},'rejected':rejected,'visionPhotos':len(vision),'labelPolicy':'controlled tool-use only; human aesthetic approval pending','promptBuilder':'production Swift function shared with app','createdAt':w.now()})
    print('DATASET',len(accepted),'rejected',len(rejected),flush=True)

def refusals(a):
    """Sparse, contract-known negatives; no invented image-content judgments."""
    import jsonschema
    report=w.read(a.root/'dataset-report.json')
    sources=[json.loads(x) for x in (a.root/'dataset_manifest.jsonl').read_text().splitlines() if json.loads(x)['split']!='vision']
    additions=collections.defaultdict(list)
    definitions=[('请使用生成式填充移除画面中的路人并补齐背景。','Phos只支持参数编辑，无法执行生成式移除，已保留原图。'),('请替换成全新的星空，并添加原图不存在的建筑。','该请求需要生成像素，超出参数编辑能力，已保留原图。'),('将整体曝光严格设置为20 EV，不接受其他数值。','20 EV超出合法曝光范围，无法按该数值执行，已保留当前参数。')]
    for i,source in enumerate(sources[::8]):
        seeds=sorted((a.root/'records').glob(source['id']+'-*.json'))
        if not seeds:continue
        seed=w.read(seeds[0]);base=seed['baseParams']
        for variant in range(2):
            instruction,summary=definitions[(i+variant)%len(definitions)]
            record={k:v for k,v in seed.items() if k not in ('renderPath','quality','imageSHA256','plan','crop')}
            record.update(id=source['id']+'-refusal-%d'%variant,task='edit',instruction=instruction,plan={'summary':summary,'adjustments':{},'masks':[]},labelType='controlled-refusal',requiresRefusal=True,protectedFields=sorted(base),provenance='unsupported operation or out-of-range exact request, known from product contract; no aesthetic label')
            record['operationId']=record['id'];dest=a.root/'renders'/record['id'];w.worker(a,'protocol',record,dest/'protocol')
            jsonschema.Draft202012Validator(w.read(dest/'protocol/edit-schema.json')).validate(record['plan'])
            w.worker(a,'render',record,dest)
            if w.read(dest/'before-params.json')!=w.read(dest/'after-params.json'):raise ValueError('Refusal changed parameters')
            with Image.open(dest/'before.jpg') as im:ImageOps.contain(im.convert('RGB'),(336,336)).save(dest/'model-input.jpg',quality=95)
            record.update(renderPath=str(dest.relative_to(a.root)),imageSHA256=source['sha256'],quality={'status':'synthetic_verified','humanAestheticApproval':False,'protectedFieldsUnchanged':True})
            w.write(a.root/'records'/(record['id']+'.json'),record)
            additions[source['split']].append({'id':record['id'],'images':[str((dest/'model-input.jpg').resolve())],'messages':[{'role':'user','content':(dest/'protocol/prompt.txt').read_text()},{'role':'assistant','content':serialize_target(record['plan'])}],'task':'edit','groupId':source['groupId'],'sourceId':source['id'],'promptVariant':'production-shared-builder-v2','labelType':'synthetic_verified'})
    for name,rows in additions.items():
        path=a.root/'sft'/(name+'.jsonl');old=[json.loads(x) for x in path.read_text().splitlines()];ids={r['id'] for r in rows};combined=[r for r in old if r['id'] not in ids]+rows
        path.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in combined));report['counts'][name]=len(combined)
    report['records']=sum(report['counts'].values());report['refusalRecords']=sum(map(len,additions.values()));w.write(a.root/'dataset-report.json',report)
    rows=[r for rows in additions.values() for r in rows];path=a.root/'refusal-preflight-data';path.mkdir(exist_ok=True)
    (path/'train.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows));(path/'validation.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows[:2]));print('REFUSALS',len(rows),flush=True)

def audit(a):
    report=w.read(a.root/'dataset-report.json');splits=w.read(a.root/'split-manifest.json');issues=[];hashsplit={};groupsplit={}
    sources=[json.loads(x) for x in (a.root/'dataset_manifest.jsonl').read_text().splitlines()]
    for s in sources:
        if w.sha(a.root/s['path'])!=s['sha256']:issues.append('hash:'+s['id'])
        for table,key in ((hashsplit,s['sha256']),(groupsplit,s['groupId'])):
            if key in table and table[key]!=s['split']:issues.append('leak:'+s['id'])
            table[key]=s['split']
    for i,s in enumerate(sources):
        for other in sources[:i]:
            if sum(x!=y for x,y in zip(s['dHash'],other['dHash']))<6:issues.append('near-duplicate:'+s['id']+'/'+other['id'])
    for name in ('train','validation','test'):
        for line in (a.root/'sft'/(name+'.jsonl')).read_text().splitlines():
            row=json.loads(line);record=w.read(a.root/'records'/(row['id']+'.json'));prompt=(a.root/record['renderPath']/'protocol/prompt.txt').read_text()
            if prompt!=row['messages'][0]['content']:issues.append('prompt:'+row['id'])
            if record['split']!=name:issues.append('split:'+row['id'])
    # Rejected candidates are excluded, retained in the report, and never exported.
    if not report['records']:issues.append('empty export')
    w.write(a.root/'data-audit.json',{'status':'passed' if not issues else 'failed','issues':issues,'sourceHashes':len(hashsplit),'authorGroups':len(groupsplit),'sourceSplitCounts':splits['photos'],'note':'Token preflight and human aesthetic approval are separate gates.'})
    if issues:raise ValueError(issues[:10])
    print('AUDIT passed',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=['protocol','collect','prepare','refusals','audit']);p.add_argument('--root',type=Path,required=True);p.add_argument('--legacy',type=Path,required=True);p.add_argument('--worker',type=Path,required=True);p.add_argument('--count',type=int,default=460)
    a=p.parse_args();a.root=a.root.resolve();a.legacy=a.legacy.resolve();a.worker=a.worker.resolve();a.root.mkdir(parents=True,exist_ok=True);globals()[a.command](a)
