#!/usr/bin/env python3
"""Local Phos dataset preparation and baseline workbench. No weight training.

All commands require an explicit output root. Images and existing sidecars are
read-only. Approval is an explicit review action, never inferred from a render.
"""
import argparse
import base64
import datetime as dt
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import subprocess
import sys
import textwrap
import urllib.parse
import urllib.request
import time

REPO = Path(__file__).resolve().parents[1]
REGISTRY = REPO / 'Tools/PhotoAIData/sources.json'
VERSION = 'phos-dataset-v1'


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    temp.replace(path)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def fingerprint(record):
    fields = {k: record.get(k) for k in ('version','task','sourceId','imageSHA256','groupId','split','instruction','baseParams','plan','crop','renderPath')}
    return hashlib.sha256(json.dumps(fields,sort_keys=True,ensure_ascii=False).encode()).hexdigest()


def inside(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('Path outside dataset root')
    return path


def download(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Phos-Dataset-Workbench/1.0'})
    with urllib.request.urlopen(req, timeout=45) as response:
        data = response.read(24 * 1024 * 1024 + 1)
    if len(data) > 24 * 1024 * 1024:
        raise ValueError('Sample download exceeds 24MB')
    return data


def worker(args, command, record, out):
    out.mkdir(parents=True, exist_ok=True)
    request = out / 'request.json'
    write(request, record)
    result = subprocess.run([str(args.worker), command, str(request), str(out)], capture_output=True, text=True)
    (out / 'worker.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Phos renderer failed')


def freeze(args):
    dest = args.root / 'baseline/frozen'
    if dest.exists():
        raise ValueError('Frozen baseline exists; use a fresh root rather than overwrite it')
    dest.mkdir(parents=True)
    files = {}
    for pattern in ('Sources/Phos/*.swift', 'Scripts/*.sh', 'Info.plist', 'Package.swift'):
        for src in sorted(REPO.glob(pattern)):
            relative = str(src.relative_to(REPO))
            target = dest / 'source' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
            files[relative] = sha(src)
    binary = Path('/Applications/Phos.app/Contents/MacOS/Phos')
    env = Path.home() / 'Library/Application Support/Phos/MLX'
    model = env / 'model'
    model_files = {str(p.relative_to(model)): sha(p) for p in sorted(model.rglob('*')) if p.is_file() and '.cache' not in p.parts}
    if not model_files or not any(x.endswith('.safetensors') for x in model_files):
        raise ValueError('Expected installed model weights not found')
    packages = subprocess.check_output([str(env / '.venv/bin/python'), '-c',
        'import importlib.metadata as m; print("\\n".join(sorted(d.metadata["Name"]+"=="+d.version for d in m.distributions())))'], text=True)
    (dest / 'environment.txt').write_text(packages)
    protocol = dest / 'protocol'
    worker(args, 'protocol', {'instruction': ''}, protocol)
    source_digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    model_digest = hashlib.sha256(json.dumps(model_files, sort_keys=True).encode()).hexdigest()
    write(dest / 'manifest.json', {'version': VERSION, 'createdAt': now(), 'sourceFiles': files,
          'sourceDigest': source_digest, 'modelFiles': model_files, 'modelDigest': model_digest,
          'modelPath': str(model), 'modelConfig': read(model / 'config.json'),
          'installedBinarySHA256': sha(binary), 'platform': platform.platform(),
          'workerSHA256': sha(args.worker), 'workerPath': str(args.worker),
          'decode': {'temperature': 0, 'editMaxTokens': 1800, 'cropMaxTokens': 180},
          'coordinates': {'crop': 'normalized top-left of current preview', 'mask': 'normalized bottom-left of post-crop preview'},
          'semantics': {'sliders': 'absolute values; omitted keys preserve existing edits', 'masks': 'append only; selection normalization is reported separately', 'noOp': 'protocol accepts empty plan; current app rejects unchanged suggestion'},
          'evaluation': 'small deterministic probe suite; not a population-level quality estimate'})
    print('Frozen source, model hashes, environment, protocol and signed app identity', flush=True)


def acquire(args):
    registry = read(REGISTRY)
    acquired = []
    for source in registry['sources']:
        entry = dict(source)
        if source['kind'] == 'photo':
            path = args.root / 'assets' / source['filename']
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_bytes(download(source['url']))
            entry.update(path=str(path.relative_to(args.root)), sha256=sha(path), bytes=path.stat().st_size, status='downloaded', fetchedAt=now())
            print('Acquired', source['id'], entry['bytes'], flush=True)
        acquired.append(entry)
    evidence = args.root / 'sources/evidence'
    evidence.mkdir(parents=True, exist_ok=True)
    # Preserve small primary-source documents, not restricted datasets.
    urls = {
        'skimage-data.html': 'https://scikit-image.org/docs/0.25.x/api/skimage.data.html',
        'fivek-adobe.txt': 'https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt',
        'fivek-adobe-mit.txt': 'https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt',
        'ppr10k-readme.md': 'https://raw.githubusercontent.com/csjliang/PPR10K/master/README.md',
        'gier-home.html': 'https://sites.google.com/view/gierdataset/home',
        'gaic-readme.md': 'https://raw.githubusercontent.com/HuiZeng/Grid-Anchor-based-Image-Cropping/master/README.md'}
    documents = []
    for name, url in urls.items():
        try:
            p = evidence / name
            p.write_bytes(download(url))
            documents.append({'url': url, 'path': str(p.relative_to(args.root)), 'sha256': sha(p), 'fetchedAt': now()})
        except Exception as error:
            documents.append({'url': url, 'error': str(error), 'status': 'not-cached'})
    write(args.root / 'sources/manifest.json', {'createdAt': now(), 'sources': acquired, 'evidence': documents,
          'note': 'Four public-domain/CC0 pipeline fixtures are not an expert-retouching dataset. Restricted dataset images were not downloaded.'})


def render(args, record):
    source = next((s for s in read(args.root / 'sources/manifest.json')['sources'] if s['id'] == record['sourceId']), None)
    if not source or source.get('status') != 'downloaded':
        raise ValueError('Source not acquired')
    request = dict(record)
    request['inputImage'] = str(inside(args.root, source['path']))
    # Version each render. A failed correction cannot replace a previously
    # reviewed preview or silently preserve an approval for different pixels.
    out = inside(args.root, 'renders/' + record['id'] + '-' + secrets.token_hex(4))
    worker(args, 'protocol', record, out/'protocol')
    import jsonschema
    jsonschema.validate(record['crop'] if record['task']=='crop' else record['plan'],read(out/'protocol'/('crop-schema.json' if record['task']=='crop' else 'edit-schema.json')))
    worker(args, 'render', request, out)
    record.update(renderPath=str(out.relative_to(args.root)), imageSHA256=source['sha256'])
    write(args.root / 'records' / (record['id'] + '.json'), record)


def generate(args):
    if list((args.root / 'records').glob('*.json')):
        raise ValueError('Records already exist; replay them instead of overwriting review state')
    definitions = [
        ('global', '整体曝光设置为 0.2 EV，其他参数保持不变，不要新增蒙版。', {'exposure': 0.2}, {}, [], {'params.exposure': 0.2}, []),
        ('hsl', '只用 HSL 将绿色饱和度降低至 -15；全局参数保持不变，不要新增蒙版。', {}, {'hsl': {'green': {'sat': -15}}}, [], {'params.hsl.green.sat': -15}, []),
        ('curve', '只用亮度曲线轻提中间调，控制点设为 (0,0)、(0.25,0.25)、(0.5,0.55)、(0.75,0.75)、(1,1)。全局参数保持不变，不要新增蒙版。', {}, {'curves': {'luma': [[0,0],[.25,.25],[.5,.55],[.75,.75],[1,1]]}}, [], {'params.lumaCurve.points': [[0,0],[.25,.25],[.5,.55],[.75,.75],[1,1]]}, []),
        ('highlights', '只创建亮度范围蒙版压暗亮区，局部曝光 -0.3 EV。全局参数保持不变。', {}, {}, [{'kind':'luminanceRange','target':'highlights','brightness':'darken','inverted':False,'geometry':{'lumLow':.65,'lumHigh':1,'lumSoft':.15},'adjustments':{'exposure':-.3}}], {'maskCount':1,'maskTarget':'highlights','maskExposure':-.3}, []),
        ('background', '只用人物蒙版压暗背景，局部曝光 -0.3 EV，保留人物；全局参数保持不变。', {}, {}, [{'kind':'person','target':'background','brightness':'darken','inverted':True,'adjustments':{'exposure':-.3}}], {'maskCount':1,'maskTarget':'background','maskExposure':-.3}, []),
        ('noop', '保持当前照片全部参数不变，不做任何调整，不要新增蒙版。', {}, {}, [], {'unchanged':True}, []),
        ('grading', '只调整阴影颜色分级：色相210度、饱和度8；全局参数保持不变，不要新增蒙版。', {}, {'grading':{'shadows':{'hue':210,'sat':8}}}, [], {'params.gradeShadow.hue':210,'params.gradeShadow.sat':8}, []),
        ('existing', '保留已有曝光、颗粒与曲线；只用 HSL 将绿色饱和度降低至 -15，不要新增蒙版。', {}, {'hsl':{'green':{'sat':-15}}}, [], {'params.hsl.green.sat':-15}, [])]
    assignments = [('skimage-coffee','global'),('skimage-chelsea','hsl'),('skimage-rocket','curve'),('skimage-coffee','highlights'),('skimage-astronaut','background'),('skimage-chelsea','noop'),('skimage-rocket','grading'),('skimage-coffee','existing')]
    defaults = read(args.root / 'baseline/frozen/protocol/defaults.json')
    for number, (source_id, name) in enumerate(assignments, 1):
        _, instruction, adjustments, advanced, masks, expected, _ = next(x for x in definitions if x[0] == name)
        plan = {'summary':'受控操作样本：' + name,'adjustments':adjustments,'masks':masks,**advanced}
        base = dict(defaults)
        if name == 'existing':
            base['exposure'] = .4; base['grain'] = 12
            base['lumaCurve'] = {'points':[[0,0],[.25,.25],[.5,.53],[.75,.75],[1,1]]}
        record = {'version':VERSION,'id':'probe-%02d-%s' % (number,name),'task':'edit','sourceId':source_id,
                  'groupId':source_id,'split':'test','instruction':instruction,'baseParams':base,'plan':plan,
                  'expected':expected,'allowedGlobals':list(adjustments),'allowedAdvanced':list(advanced),
                  'provenance':'deterministic Phos operation, not an expert aesthetic target','review':{'decision':'pending','notes':''}}
        render(args, record)
    for n, (source_id, box, instruction) in enumerate([
        ('skimage-astronaut',{'x':0,'y':0,'width':1,'height':1},'保留完整原构图，不要裁切，不要旋转。'),
        ('skimage-rocket',{'x':0,'y':0,'width':1,'height':1},'保留完整原构图，不要裁切，不要旋转。'),
        ('skimage-coffee',{'x':.1,'y':.1,'width':.8,'height':.8},'按明确边界裁切：左上角 x=0.1、y=0.1，宽0.8、高0.8。不要旋转。'),
        ('skimage-chelsea',{'x':.05,'y':0,'width':.9,'height':1},'仅裁去左右各5%，保留完整高度，不要旋转。')],9):
        render(args, {'version':VERSION,'id':'probe-%02d-crop' % n,'task':'crop','sourceId':source_id,'groupId':source_id,'split':'test','instruction':instruction,'crop':box,'expected':{'crop':box},'provenance':'explicit crop geometry fixture; aesthetic acceptability requires human review','review':{'decision':'pending','notes':''}})
    print('Prepared 12 held-out pipeline probes on four source groups; none approved for training',flush=True)
    write(args.root/'baseline/suite.json',{'version':VERSION,'createdAt':now(),'records':records(args)})


def records(args):
    return [read(p) for p in sorted((args.root / 'records').glob('*.json'))]


def add(args):
    record=read(args.record)
    if record.get('version')!=VERSION or record.get('task') not in ('edit','crop') or record.get('split') not in ('train','validation','test'):
        raise ValueError('Invalid record version, task or split')
    if not record.get('instruction') or not record.get('groupId'):
        raise ValueError('instruction and groupId are required')
    destination=inside(args.root,'records/'+record['id']+'.json')
    if destination.exists(): raise ValueError('Record ID already exists')
    entry=next(x for x in read(args.root/'sources/manifest.json')['sources'] if x['id']==record['sourceId'])
    for existing in records(args):
        if (existing['groupId']==record['groupId'] or existing['imageSHA256']==entry['sha256']) and existing['split']!=record['split']:
            raise ValueError('Source image/group already assigned to a different split')
    record['review']={'decision':'pending','notes':'New sample requires review'}
    render(args,record)
    print('Added and rendered',record['id'],'as pending; baseline suite unchanged')


def prompt_from_frozen(root, record, params):
    source = (root / 'baseline/frozen/source/Sources/Phos/LocalPhotoAI.swift').read_text()
    method = 'func crop(' if record['task'] == 'crop' else 'func plan('
    part = source.split(method,1)[1].split('let prompt = """',1)[1].split('"""',1)[0]
    prompt = textwrap.dedent(part).strip('\n')
    context = json.loads(json.dumps(params))
    for mask in context.get('masks',[]):
        mask['strokes'] = []; mask['refinements'] = []
    prompt = prompt.replace('\\(instruction)',record['instruction']).replace('\\(current)',json.dumps(context,ensure_ascii=False,sort_keys=True,separators=(',',':')))
    if '\\(' in prompt:
        raise ValueError('Unexpanded production prompt interpolation')
    return prompt


def compare(record, result, base, after):
    checks = {}
    expected = record['expected']
    if record['task'] == 'crop':
        actual = result['rawJSON']
        checks['requestedCrop'] = all(abs(actual.get(k,-10)-v) < .011 for k,v in expected['crop'].items())
        return checks
    target=read(Path(result['root'])/record['renderPath']/'after-params.json') if result.get('root') else None
    if target:
        checks['matchesRequestedNonMaskState']={k:v for k,v in after.items() if k!='masks'}=={k:v for k,v in target.items() if k!='masks'}
    allowed = set(record.get('allowedGlobals',[]))
    keys = read(result['schemaPath'])['properties']['adjustments']['properties']
    changed = [k for k in keys if after.get(k) != base.get(k)]
    checks['preservesUnrelatedGlobals'] = all(k in allowed for k in changed)
    for tool, paths in [('hsl',['hsl']),('curves',['curve','lumaCurve','curveR','curveG','curveB']),('grading',['gradeShadow','gradeMid','gradeHigh'])]:
        if tool not in record.get('allowedAdvanced',[]):
            checks['preserves-' + tool] = all(after.get(p)==base.get(p) for p in paths)
    for path, value in expected.items():
        if path.startswith('params.'):
            actual = after
            for key in path.split('.')[1:]: actual = actual[key]
            checks[path] = actual == value
    masks = after.get('masks',[])[len(base.get('masks',[])):]
    checks['maskCount'] = len(masks) == expected.get('maskCount',0)
    if 'maskExposure' in expected:
        checks['maskExposure'] = bool(masks) and all(abs(m['adjust']['exposure']-expected['maskExposure']) < 1e-7 for m in masks)
        raw_masks = result['rawJSON'].get('masks',[])
        # The production protocol explicitly lets target=background infer
        # inversion. Missing optional inverted is not itself a model error.
        checks['rawSelectionAndSign'] = bool(raw_masks) and all(m.get('target')==expected['maskTarget'] and m.get('brightness')=='darken' and m.get('adjustments',{}).get('exposure',0)<0 and (m.get('inverted',expected['maskTarget']=='background')==(expected['maskTarget']=='background')) for m in raw_masks)
    if expected.get('unchanged'):
        checks['unchanged'] = after == base
    return checks


def baseline(args):
    frozen = read(args.root / 'baseline/frozen/manifest.json')
    if sha(args.worker) != frozen['workerSHA256']:
        raise ValueError('Worker changed since freeze; use the original worker or a new baseline root')
    model=Path(frozen['modelPath'])
    for relative, expected in frozen['modelFiles'].items():
        if sha(model/relative)!=expected:
            raise ValueError('Installed model content changed: '+relative)
    with urllib.request.urlopen('http://127.0.0.1:8765/v1/models',timeout=4) as response:
        models = json.load(response)
    if not any(m['id']==frozen['modelPath'] for m in models['data']):
        raise ValueError('Active server model differs from frozen baseline')
    summary = []
    for record in read(args.root/'baseline/suite.json')['records']:
        out = args.root / 'baseline/results' / record['id']
        if (out/'result.json').exists() and not args.rerun:
            summary.append(read(out/'result.json')); continue
        print('Baseline',record['id'],flush=True)
        worker(args,'protocol',record,out/'protocol')
        source = args.root / record['renderPath']
        params = read(source/'before-params.json')
        prompt = prompt_from_frozen(args.root,record,params)
        schema_path = out/'protocol'/('crop-schema.json' if record['task']=='crop' else 'edit-schema.json')
        body = {'model':frozen['modelPath'],'messages':[{'role':'user','content':[{'type':'text','text':prompt},{'type':'image_url','image_url':{'url':'data:image/jpeg;base64,'+base64.b64encode((source/'before.jpg').read_bytes()).decode()}}]}], 'max_tokens':180 if record['task']=='crop' else 1800,'temperature':0,'response_format':{'type':'json_schema','json_schema':{'name':'phos_edit','schema':read(schema_path)}}}
        (out/'prompt.txt').write_text(prompt)
        write(out/'request-metadata.json',{k:v for k,v in body.items() if k!='messages'})
        started=time.monotonic()
        result={'id':record['id'],'task':record['task'],'sourceId':record['sourceId'],'root':str(args.root),'attempts':1,'noAutomaticRetry':True,'schemaPath':str(schema_path),'humanAestheticReview':'pending'}
        try:
            req=urllib.request.Request('http://127.0.0.1:8765/v1/chat/completions',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=240) as response: envelope=json.load(response)
            write(out/'response.json',envelope)
            choice=envelope['choices'][0]; raw=choice['message']['content']; (out/'raw.txt').write_text(raw)
            result['finishReason']=choice.get('finish_reason'); result['truncated']=choice.get('finish_reason')=='length'
            value=json.loads(raw); result['rawJSON']=value; result['rawJSONParseable']=True
            try:
                import jsonschema
                jsonschema.validate(value,read(schema_path)); result['rawSchemaValid']=True
            except ImportError:
                result['rawSchemaValid']=None; result['schemaValidationNote']='jsonschema not installed; not scored'
            except Exception as error:
                result['rawSchemaValid']=False; result['schemaError']=str(error)[:1000]
            candidate=dict(record); candidate.pop('plan',None); candidate.pop('crop',None)
            candidate['crop' if record['task']=='crop' else 'plan']=value
            registry=read(args.root/'sources/manifest.json')['sources']; entry=next(x for x in registry if x['id']==record['sourceId'])
            candidate['inputImage']=str(inside(args.root,entry['path']))
            worker(args,'render',candidate,out/'rendered')
            rendering=read(out/'rendered/render.json'); result['render']=rendering
            checks=compare(record,result,params,read(out/'rendered/after-params.json'))
            if rendering['directionChecked']:
                checks['rawRenderedDirection']=not rendering.get('rawDirectionError')
                checks['canonicalRenderedDirection']=not rendering.get('directionError')
            result['checks']=checks
            result['firstOutputPass']=all(checks.values()) and result['rawSchemaValid'] is True and not result['truncated']
            result['status']='evaluated'
        except Exception as error:
            result.update(status='failed',error=str(error),firstOutputPass=False)
            result.setdefault('rawJSONParseable',False)
        result['seconds']=round(time.monotonic()-started,3)
        write(out/'result.json',result); summary.append(result)
        write(args.root/'baseline/report.json',{'createdAt':now(),'scope':'12 pipeline probes on four groups; not a representative aesthetic benchmark','suiteSHA256':sha(args.root/'baseline/suite.json'),'modelDigest':frozen['modelDigest'],'completed':len(summary),'passedFirstOutput':sum(x.get('firstOutputPass',False) for x in summary),'results':summary})
    print('Baseline:',sum(x.get('firstOutputPass',False) for x in summary),'/',len(summary),'first-output passes',flush=True)


def rescore(args):
    report=read(args.root/'baseline/report.json')
    suite={x['id']:x for x in read(args.root/'baseline/suite.json')['records']}
    results=[]
    for result in report['results']:
        result['root']=str(args.root)
        out=args.root/'baseline/results'/result['id']
        if result['status']=='evaluated':
            checks=compare(suite[result['id']],result,read(out/'rendered/before-params.json'),read(out/'rendered/after-params.json'))
            rendering=result['render']
            if rendering['directionChecked']:
                checks['rawRenderedDirection']=not rendering.get('rawDirectionError')
                checks['canonicalRenderedDirection']=not rendering.get('directionError')
            result['checks']=checks
            result['firstOutputPass']=all(checks.values()) and result.get('rawSchemaValid') is True and not result.get('truncated',False)
        write(out/'result.json',result); results.append(result)
    report.update(results=results,passedFirstOutput=sum(x.get('firstOutputPass',False) for x in results),rescoredAt=now(),evaluatorSHA256=sha(Path(__file__)))
    write(args.root/'baseline/report.json',report)
    print('Rescored existing responses without new model calls:',report['passedFirstOutput'],'/',report['completed'])


def validate(args):
    groups={}; hashes={}; issues=[]
    registry={x['id']:x for x in read(args.root/'sources/manifest.json')['sources']}
    for r in records(args):
        for key, table in [(r['groupId'],groups),(r['imageSHA256'],hashes)]:
            if key in table and table[key]!=r['split']: issues.append('Cross-split group/image: '+r['id'])
            table[key]=r['split']
        source=registry[r['sourceId']]
        if sha(inside(args.root,source['path']))!=r['imageSHA256']: issues.append('Changed source: '+r['id'])
        if not (args.root/r['renderPath']/'render.json').exists(): issues.append('Missing render: '+r['id'])
        if r['review']['decision']=='approved' and (r['review'].get('renderSHA256')!=sha(args.root/r['renderPath']/'after.jpg') or r['review'].get('recordFingerprint')!=fingerprint(r)): issues.append('Approval is stale: '+r['id'])
    report={'status':'passed' if not issues else 'failed','records':len(records(args)),'groups':len(groups),'issues':issues,'createdAt':now()}
    write(args.root/'validation.json',report); print(json.dumps(report,ensure_ascii=False))
    if issues: raise ValueError('Dataset validation failed')


def export(args):
    validate(args)
    registry={x['id']:x for x in read(args.root/'sources/manifest.json')['sources']}
    selected=[]; excluded=[]
    for r in records(args):
        reason=None
        if r['split']!='train': reason='not-training-split'
        elif r['review']['decision']!='approved': reason='not-human-approved'
        elif args.purpose=='release' and registry[r['sourceId']].get('releaseEligible') is not True: reason='license-ineligible'
        elif args.purpose=='research' and registry[r['sourceId']].get('researchEligible') is not True: reason='research-permission-unverified'
        if reason: excluded.append({'id':r['id'],'reason':reason}); continue
        # Framework-neutral, image-bearing SFT records. No inference API changes.
        rendered=args.root/r['renderPath']
        prompt=prompt_from_frozen(args.root,r,read(rendered/'before-params.json'))
        selected.append({'id':r['id'],'image':str(rendered/'before.jpg'),'messages':[{'role':'user','content':'<image>\n'+prompt},{'role':'assistant','content':json.dumps(r.get('plan',r.get('crop')),ensure_ascii=False,separators=(',',':'))}], 'task':r['task'],'sourceId':r['sourceId'],'groupId':r['groupId']})
    target=args.root/'exports'/args.purpose; target.mkdir(parents=True,exist_ok=True)
    (target/'train.jsonl').write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in selected))
    write(target/'manifest.json',{'purpose':args.purpose,'exported':len(selected),'excluded':excluded,'format':'framework-neutral; adapt and verify image-token/completion masking before training','createdAt':now()})
    print('Exported',len(selected),'approved training records; excluded',len(excluded))


def review(args):
    page=REPO/'Tools/PhotoAIData/review.html'
    token=secrets.token_urlsafe(24)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*values): pass
        def send(self,status,body,kind='application/json'):
            data=body.encode() if isinstance(body,str) else body
            self.send_response(status); self.send_header('Content-Type',kind); self.send_header('Content-Length',str(len(data))); self.send_header('Cache-Control','no-store'); self.send_header('X-Content-Type-Options','nosniff'); self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            path=urllib.parse.urlsplit(self.path).path
            try:
                if path=='/': return self.send(200,page.read_text().replace('__TOKEN__',token),'text/html; charset=utf-8')
                if path=='/api/records':
                    data=[]
                    for r in records(args):
                        x=dict(r); x['render']=read(args.root/r['renderPath']/'render.json')
                        before=read(args.root/r['renderPath']/'before-params.json')
                        after=read(args.root/r['renderPath']/'after-params.json')
                        x['parameterDiff']={key:{'before':before.get(key),'after':after.get(key)} for key in sorted(set(before)|set(after)) if before.get(key)!=after.get(key)}
                        result=args.root/'baseline/results'/r['id']/'result.json'
                        x['baseline']=read(result) if result.exists() else None
                        data.append(x)
                    return self.send(200,json.dumps(data,ensure_ascii=False))
                if path.startswith('/files/'):
                    f=inside(args.root,urllib.parse.unquote(path[7:]))
                    if f.suffix not in ('.jpg','.png'): raise ValueError('Only preview images are served')
                    return self.send(200,f.read_bytes(),'image/png' if f.suffix=='.png' else 'image/jpeg')
                self.send(404,'{}')
            except Exception as error: self.send(400,json.dumps({'error':str(error)}))
        def do_POST(self):
            try:
                if self.path not in ('/api/review','/api/plan') or self.headers.get('X-Review-Token')!=token: return self.send(403,'{}')
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<16384: raise ValueError('Invalid review size')
                body=json.loads(self.rfile.read(length))
                p=inside(args.root,'records/'+body['id']+'.json'); r=read(p)
                if self.path=='/api/plan':
                    value=body['target']
                    if not isinstance(value,dict): raise ValueError('Target must be a JSON object')
                    r['crop' if r['task']=='crop' else 'plan']=value
                    r['review']={'decision':'pending','notes':'Target corrected; approval required'}
                    render(args,r)
                    return self.send(200,json.dumps({'status':'rendered','id':r['id']}))
                if body['decision'] not in ('approved','rejected','needs-correction','pending'): raise ValueError('Invalid decision')
                rendering=read(args.root/r['renderPath']/'render.json')
                if body['decision']=='approved' and (rendering.get('directionError') or rendering.get('normalizations')): raise ValueError('Plan needs normalization or direction correction before approval')
                decision={'decision':body['decision'],'notes':str(body.get('notes',''))[:4000],'reviewedAt':now(),'renderSHA256':sha(args.root/r['renderPath']/'after.jpg'),'recordFingerprint':fingerprint(r)}
                audit=args.root/'reviews/events.jsonl'; audit.parent.mkdir(parents=True,exist_ok=True)
                with audit.open('a') as f: f.write(json.dumps({'id':r['id'],'previous':r['review'],'review':decision},ensure_ascii=False)+'\n')
                r['review']=decision; write(p,r); self.send(200,json.dumps(decision,ensure_ascii=False))
            except Exception as error: self.send(400,json.dumps({'error':str(error)}))
    server=http.server.HTTPServer(('127.0.0.1',args.port),Handler)
    print('Review URL: http://127.0.0.1:%d (local only)' % args.port,flush=True)
    server.serve_forever()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--worker',type=Path,default=REPO/'build/photo-ai-data/photo-ai-data')
    sub=p.add_subparsers(dest='command',required=True)
    for name in ('freeze','acquire','generate','validate','rescore'): sub.add_parser(name)
    b=sub.add_parser('baseline'); b.add_argument('--rerun',action='store_true')
    e=sub.add_parser('export'); e.add_argument('--purpose',choices=('research','release'),required=True)
    r=sub.add_parser('review'); r.add_argument('--port',type=int,default=8766)
    replay=sub.add_parser('replay'); replay.add_argument('id')
    adding=sub.add_parser('add'); adding.add_argument('record',type=Path)
    args=p.parse_args(); args.root=args.root.expanduser().resolve(); args.worker=args.worker.expanduser().resolve()
    args.root.mkdir(parents=True,exist_ok=True)
    if args.command=='replay':
        record=read(inside(args.root,'records/'+args.id+'.json')); record['review']={'decision':'pending','notes':'Re-rendered; previous approval invalidated'}; render(args,record)
    else: globals()[args.command](args)


if __name__=='__main__':
    try: main()
    except Exception as error:
        print('ERROR:',error,file=sys.stderr); sys.exit(1)
