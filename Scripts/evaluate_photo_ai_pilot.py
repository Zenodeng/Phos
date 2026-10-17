#!/usr/bin/env python3
"""Paired, single-attempt held-out inference for a base and pilot adapter."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import time

os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1';os.environ['TOKENIZERS_PARALLELISM']='false'
import mlx.core as mx
from mlx_vlm import generate,load
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.structured import build_json_schema_logits_processor

spec=importlib.util.spec_from_file_location('workbench',Path(__file__).with_name('photo_ai_workbench.py'))
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)


def clean_params(params):
    result=dict(params)
    result['masks']=[{k:v for k,v in mask.items() if k not in ('id','name')} for mask in result.get('masks',[])]
    return result


def main(args):
    mx.set_cache_limit(256*1024**2);mx.set_memory_limit(9_000_000_000)
    model,processor=load(str(args.model),adapter_path=str(args.adapter) if args.adapter else None);model.eval()
    candidates=[json.loads(x) for x in (args.root/'sft-compact/test.jsonl').read_text().splitlines()]
    # One complete set of task types from an author-disjoint test photo.
    candidates=candidates[:10]
    results=[];args.out.mkdir(parents=True,exist_ok=True)
    for row in candidates:
        record=w.read(args.root/'records'/(row['id']+'.json'));dest=args.out/row['id'];dest.mkdir(exist_ok=True)
        schema=w.read(args.root/record['renderPath']/'protocol'/('crop-schema.json' if row['task']=='crop' else 'edit-schema.json'))
        prompt=apply_chat_template(processor,model.config,row['messages'][:-1],add_generation_prompt=True,num_images=1)
        logits=build_json_schema_logits_processor(processor.tokenizer,schema)
        started=time.monotonic();result={'id':row['id'],'task':row['task'],'firstOutputPass':False}
        try:
            generated=generate(model,processor,prompt,image=row['images'],max_tokens=180 if row['task']=='crop' else 600,temperature=0,logits_processors=[logits],verbose=False,prefill_step_size=512)
            raw=generated.text;(dest/'raw.txt').write_text(raw)
            plan=json.loads(raw);result['raw']=plan
            request=dict(record,inputImage=str(args.root/next(s['path'] for s in w.read(args.root/'sources/manifest.json')['sources'] if s['id']==record['sourceId'])))
            request['crop' if row['task']=='crop' else 'plan']=plan
            w.worker(args,'render',request,dest/'rendered')
            target=w.read(args.root/record['renderPath']/'after-params.json');actual=w.read(dest/'rendered/after-params.json')
            result['sameRenderedParameters']=clean_params(target)==clean_params(actual)
            result['rawDirectionCorrect']=True
            if row['task']=='edit' and record['plan']['masks']:
                expected=record['plan']['masks'];predicted=plan['masks']
                result['rawDirectionCorrect']=len(expected)==len(predicted) and all(a.get('target')==b.get('target') and a.get('brightness')==b.get('brightness') and a.get('adjustments')==b.get('adjustments') for a,b in zip(expected,predicted))
            result['firstOutputPass']=result['sameRenderedParameters'] and result['rawDirectionCorrect']
            result['generatedTokens']=getattr(generated,'generation_tokens',None)
        except Exception as error:result['error']=str(error)[:1200]
        result['seconds']=round(time.monotonic()-started,3);results.append(result)
        w.write(args.out/'results.json',{'adapter':str(args.adapter) if args.adapter else None,'attemptsPerTask':1,'sameConstrainedDecodingForBoth':True,'scope':'10 controlled operations on one author-held-out photo; not aesthetic or production release evaluation','passed':sum(r['firstOutputPass'] for r in results),'completed':len(results),'results':results,'mlxPeakGB':mx.get_peak_memory()/1e9})
        print('EVAL',row['id'],result['firstOutputPass'],result.get('error',''),flush=True);mx.clear_cache()


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--model',type=Path,required=True);p.add_argument('--adapter',type=Path);p.add_argument('--out',type=Path,required=True);p.add_argument('--worker',type=Path,required=True)
    args=p.parse_args();args.root=args.root.resolve();args.out=args.out.resolve();args.model=args.model.resolve();args.worker=args.worker.resolve();main(args)
