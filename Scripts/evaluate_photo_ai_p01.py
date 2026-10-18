#!/usr/bin/env python3
"""Same protocol/evaluator for original, incumbent and candidate; validation default."""
import argparse,importlib.util,json,os,time,hashlib,collections,importlib.metadata
from pathlib import Path
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',TOKENIZERS_PARALLELISM='false')
import mlx.core as mx
from mlx_vlm import load,generate
from mlx_vlm.prompt_utils import apply_chat_template
from photo_ai_protocol import build_logits_processor, VERSION, FINGERPRINT
spec=importlib.util.spec_from_file_location('p01',Path(__file__).with_name('photo_ai_p01.py'));p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p);w=p.w

def equivalent(a,b):
    if isinstance(a,dict) and isinstance(b,dict):return set(a)==set(b) and all(equivalent(a[k],b[k]) for k in a if k not in ('id','name'))
    if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(equivalent(x,y) for x,y in zip(a,b))
    if isinstance(a,(float,int)) and not isinstance(a,bool) and isinstance(b,(float,int)):return abs(a-b)<1e-6
    return a==b

def score(record,raw,target,actual,render):
    protected=all(equivalent(record['baseParams'][k],actual[k]) for k in record.get('protectedFields',[]))
    if record['task']=='crop':matched=all(abs(raw.get(k,-10)-v)<1e-6 for k,v in record['crop'].items())
    else:matched=equivalent(target,actual)
    raw_direction=not render.get('rawDirectionError') and not render.get('normalizations')
    return {'requestedOperationMatched':matched,'protectedFieldsUnchanged':protected,'rawDirectionCorrect':raw_direction,'success':matched and protected and raw_direction}

def main(a):
    fingerprint=w.read(a.root/'baseline/model-fingerprint.json')
    for relative,digest in fingerprint['baseFiles'].items():
        if w.sha(a.model/relative)!=digest:raise ValueError('Base fingerprint mismatch: '+relative)
    if a.variant=='base' and a.adapter:raise ValueError('Base evaluation must not load an adapter')
    if a.variant!='base' and not a.adapter:raise ValueError('Named adapted variant requires an explicit adapter')
    if a.adapter:
        manifest=w.read(a.root/'baseline/model-fingerprint.json');base_manifest=a.adapter/'manifest.json'
        if not base_manifest.exists():raise ValueError('Explicit adapter manifest required for reproducible evaluation')
        if base_manifest.exists():
            m=w.read(base_manifest)
            if m.get('baseRevision')!=manifest['baseRevision']:raise ValueError('Adapter base revision mismatch')
            if m.get('adapterSHA256') and w.sha(a.adapter/'adapters.safetensors')!=m['adapterSHA256']:raise ValueError('Adapter weight hash mismatch')
    source = a.cases or (a.root/'sft'/(a.split+'.jsonl'))
    rows=[json.loads(x) for x in source.read_text().splitlines() if x.strip()]
    if a.limit: rows=rows[:a.limit]
    inputs = {str(source):w.sha(source), str(a.worker):w.sha(a.worker)}
    for row in rows:
        path=a.root/'records'/(row['id']+'.json');inputs[str(path)]=w.sha(path)
        record=w.read(path)
        for path in [a.root/record['renderPath']/'after-params.json',a.root/record['renderPath']/'protocol'/('crop-schema.json' if row['task']=='crop' else 'edit-schema.json'),*[Path(x) for x in row['images']]]:
            inputs[str(path)]=w.sha(path)
    for name in ('photo_ai_protocol.py','evaluate_photo_ai_p01.py'):
        path=Path(__file__).with_name(name);inputs[str(path)]=w.sha(path)
    identity={'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT,
        'variant':a.variant,'baseFiles':fingerprint['baseFiles'],'adapterSHA256':w.sha(a.adapter/'adapters.safetensors') if a.adapter else None,
        'adapterConfigSHA256':w.sha(a.adapter/'adapter_config.json') if a.adapter else None,
        'split':a.split,'retryBudget':a.retries,'inputs':inputs,
        'versions':{k:importlib.metadata.version(k) for k in ('mlx','mlx-vlm','transformers','llguidance')}}
    identitySHA=hashlib.sha256(json.dumps(identity,sort_keys=True).encode()).hexdigest()
    report_path=a.out/'results.json';results=[]
    if report_path.exists():
        previous=w.read(report_path)
        if not a.resume or previous.get('identitySHA256')!=identitySHA:raise ValueError('Existing evaluation requires --resume with identical inputs/configuration')
        results=previous['results']
        if [x['id'] for x in results]!=[x['id'] for x in rows[:len(results)]]:raise ValueError('Resume case order mismatch')
    w.write(a.out/'input-fingerprint.json',dict(identity,identitySHA256=identitySHA))
    mx.set_cache_limit(256*1024**2);mx.set_memory_limit(8_000_000_000)
    model,processor=load(str(a.model),adapter_path=str(a.adapter) if a.adapter else None);model.eval()
    for row in rows[len(results) :]:
        record=w.read(a.root/'records'/(row['id']+'.json'));dest=a.out/row['id'];dest.mkdir(parents=True,exist_ok=True)
        schema=w.read(a.root/record['renderPath']/'protocol'/('crop-schema.json' if row['task']=='crop' else 'edit-schema.json'));prompt=row['messages'][0]['content'];attempts=[];start=time.monotonic()
        for attempt in range(a.retries+1):
            event={'attempt':attempt,'success':False}
            try:
                chat=apply_chat_template(processor,model.config,[{'role':'user','content':prompt}],add_generation_prompt=True,num_images=1)
                logits=build_logits_processor(processor.tokenizer,schema)
                result=generate(model,processor,chat,image=row['images'],max_tokens=180 if row['task']=='crop' else 800,temperature=0,logits_processors=[logits],verbose=False,prefill_step_size=512)
                raw=result.text;(dest/('raw-%d.txt'%attempt)).write_text(raw);plan=json.loads(raw)
                import jsonschema
                jsonschema.validate(plan,schema);event['schemaValid']=True;event['generatedTokens']=result.generation_tokens
                request=dict(record);request['crop' if row['task']=='crop' else 'plan']=plan
                rendered=dest/('attempt-%d'%attempt);w.worker(a,'render',request,rendered)
                event.update(score(record,plan,w.read(a.root/record['renderPath']/'after-params.json'),w.read(rendered/'after-params.json'),w.read(rendered/'render.json')))
                if event['success']:attempts.append(event);break
                event['error']='Rendered state differs from requested operation or raw mask needs correction.'
            except Exception as e:event['error']=str(e)[:600]
            attempts.append(event);prompt=row['messages'][0]['content']+'\nPrevious output failed validation: '+event['error']+' Return a corrected complete plan.'
        results.append({'id':row['id'],'sourceId':row['sourceId'],'groupId':row['groupId'],'task':row['task'],'attempts':attempts,'firstAttemptSuccess':attempts[0]['success'],'postRetrySuccess':any(x['success'] for x in attempts),'seconds':round(time.monotonic()-start,3)})
        w.write(a.out/'results.json',{'identitySHA256':identitySHA,'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT,'uniquePhotos':len({x['sourceId'] for x in rows}),'uniqueAuthorGroups':len({x['groupId'] for x in rows}),'requestedCases':len(rows),'variant':a.variant,'adapter':str(a.adapter) if a.adapter else None,'split':a.split,'scope':'controlled operations, not aesthetic quality; same Swift production prompt and renderer','results':results,'firstAttemptSuccess':sum(x['firstAttemptSuccess'] for x in results),'postRetrySuccess':sum(x['postRetrySuccess'] for x in results),'completed':len(results),'retryBudget':a.retries})
        print('EVAL',row['id'],results[-1]['firstAttemptSuccess'],flush=True);mx.clear_cache()
if __name__=='__main__':
    p1=argparse.ArgumentParser();p1.add_argument('--root',type=Path,required=True);p1.add_argument('--out',type=Path,required=True);p1.add_argument('--model',type=Path,required=True);p1.add_argument('--adapter',type=Path);p1.add_argument('--worker',type=Path,required=True);p1.add_argument('--variant',choices=['base','incumbent','candidate'],required=True);p1.add_argument('--split',choices=['validation','test'],default='validation');p1.add_argument('--cases',type=Path);p1.add_argument('--limit',type=int,default=0);p1.add_argument('--resume',action='store_true');p1.add_argument('--retries',type=int,choices=[0,1],default=1);a=p1.parse_args();a.root=a.root.resolve();a.out=a.out.resolve();a.worker=a.worker.resolve();a.out.mkdir(parents=True,exist_ok=True);main(a)
