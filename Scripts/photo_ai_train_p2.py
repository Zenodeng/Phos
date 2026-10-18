#!/usr/bin/env python3
"""P2 完整小集 LoRA 训练：在 pilot 脚本基础上放宽 swap 保护阀。

与 photo_ai_train_pilot.py 的差异（pilot 脚本保持冻结不动，作为基线证据）：
1. swap 增长阈值可配置（--max-swap-growth-mb，默认 3072），pilot 硬编码 768MiB。
   原因：16GB M1 Pro 上系统 swap 长期占用 14GB+，加载 3GB 基座后 swap 必然增长，
   768MiB 会在第 5 步就误判中止（2026-10-17 与 2026-10-18 两次实测均如此）。
2. 增加绝对内存下限保护（--min-available-gb，默认 1.0）：真正危险时仍会中止。
3. steps_per_eval / steps_per_save 可配置，避免 2563 步里做 102 次评测。
4. 适配器热启动可使用 trainer 原生编号检查点（不含 optimizer/RNG，不能精确续训）（adapter/0000100_adapters.safetensors 等）。
   注意：不要再自己复制 adapter 做快照——trainer 每个保存点已经写了编号文件，
   而且 on_train_loss_report 每 5 步就触发一次，自己复制会产生大量重复且命名错位
   （第 200 步的目录里装的可能是第 100 步的权重）。
"""
import argparse
import dataclasses
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sys
import time
from photo_ai_protocol import VERSION, FINGERPRINT, serialize_target

os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['HF_DATASETS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'

import mlx.core as mx
import numpy as np
import psutil
from mlx.utils import tree_flatten
from mlx_vlm import load
from mlx_vlm.trainer import Trainer, VLMTrainingArgs, prepare_model_for_training
from mlx_vlm.trainer.common.callbacks import TrainingCallback


def write(path,value):
    Path(path).parent.mkdir(parents=True,exist_ok=True)
    Path(path).write_text(json.dumps(value,ensure_ascii=False,indent=2,default=str)+'\n')


def rows(path): return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def memory():
    return {'rssGB':psutil.Process().memory_info().rss/1e9,'availableGB':psutil.virtual_memory().available/1e9,'systemSwapGB':psutil.swap_memory().used/1e9,'mlxPeakGB':mx.get_peak_memory()/1e9,'mlxActiveGB':mx.get_active_memory()/1e9}


class Metrics(TrainingCallback):
    def __init__(self,out,max_swap_growth_mb=3072,min_available_gb=1.0):
        self.out=out;self.start_swap=psutil.swap_memory().used;self.history=[]
        self.max_swap_growth=max_swap_growth_mb*1024**2;self.min_available=min_available_gb*1e9
    def save(self,kind,info):
        event={'kind':kind,**info,'memory':memory()};self.history.append(event)
        with (self.out/'metrics.jsonl').open('a') as f:f.write(json.dumps(event,default=str)+'\n')
        write(self.out/'progress.json',event)
        # 绝对下限：真正会把机器拖死时才中止
        available=psutil.virtual_memory().available
        if available<self.min_available:
            raise RuntimeError(f'Stopped: available memory {available/1e9:.2f} GB below floor {self.min_available/1e9:.2f} GB')
        # 相对阈值：默认放宽到 3072 MiB
        grew=psutil.swap_memory().used-self.start_swap
        if grew>self.max_swap_growth:
            raise RuntimeError(f'Stopped: system swap grew {grew/1024**2:.0f} MiB, limit {self.max_swap_growth/1024**2:.0f} MiB')
    def on_train_loss_report(self,info): self.save('train',info)
    def on_val_loss_report(self,info): self.save('validation',info)


def prepare(args):
    mx.set_cache_limit(256*1024**2)
    mx.set_memory_limit(11_000_000_000)
    mx.random.seed(1702)
    start=time.monotonic();initial_memory=memory()
    lock=json.loads((Path(__file__).resolve().parents[1]/'Tools/OptionalModel/model-manifest.json').read_text())
    for relative,expected in lock['files'].items():
        with (args.model/relative).open('rb') as handle:actual=hashlib.file_digest(handle,'sha256').hexdigest()
        if actual!=expected:raise ValueError('Base file fingerprint mismatch: '+relative)
    write(args.out/'base-fingerprint.json',lock)
    model,processor=load(str(args.model),adapter_path=str(args.adapter) if args.adapter else None)
    names=[name for name,module in model.named_modules() if name.endswith(('.q_proj','.v_proj')) and '.layers.' in name and name.startswith('language_model.')]
    layers=sorted({int(re.search(r'\.layers\.(\d+)\.',name).group(1)) for name in names})
    selected=layers[-args.layers:]
    targets=[name for name in names if int(re.search(r'\.layers\.(\d+)\.',name).group(1)) in selected]
    if not targets: raise ValueError('No language-only Q/V targets found')
    if not args.adapter:
        prepare_model_for_training(model,train_type='lora',target_modules=targets,lora_rank=args.rank,lora_alpha=2*args.rank,lora_dropout=0)
    train=rows(args.data/'train.jsonl');val=rows(args.data/'validation.jsonl')
    if args.mode == 'train':
        proof=args.data/'protocol-verification.json'
        if not proof.exists():raise ValueError('Run verify_photo_ai_protocol.py and use its versioned export before training')
        contract=json.loads(proof.read_text())
        if contract.get('decoderFingerprint')!=FINGERPRINT or contract.get('canonicalCompatible')!=contract.get('total'):raise ValueError('Training/decoder compatibility gate failed')
        for split in ('train','validation'):
            path=args.data/(split+'.jsonl')
            if contract['hashes'].get(str(path.resolve()))!=hashlib.sha256(path.read_bytes()).hexdigest():raise ValueError('Verified dataset changed: '+split)
        for row in train+val:
            if row.get('serializationVersion')!=VERSION or row.get('decoderFingerprint')!=FINGERPRINT or row['messages'][-1]['content']!=serialize_target(json.loads(row['messages'][-1]['content'])):raise ValueError('Noncanonical training row: '+row['id'])
    write(args.out/'validation-coverage.json',{'policy':'full dataset; val_batches=-1; no shortest-only sampling','batchSize':1,'count':len(val),'ids':[r['id'] for r in val],'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT,'dataHashes':{n:hashlib.sha256((args.data/(n+'.jsonl')).read_bytes()).hexdigest() for n in ('train','validation')}})
    adapter_file=args.out/'adapter/adapters.safetensors'
    config=VLMTrainingArgs(batch_size=1,iters=args.iters,max_seq_length=args.max_seq_length,train_on_completions=True,gradient_accumulation_steps=1,grad_checkpoint=True,learning_rate=args.learning_rate,steps_per_report=1 if args.iters<5 else 5,steps_per_eval=args.steps_per_eval,val_batches=-1,steps_per_save=args.steps_per_save,cache_size=2,adapter_file=str(adapter_file))
    callback=Metrics(args.out,args.max_swap_growth_mb,args.min_available_gb)
    trainer=Trainer(model,config,train_dataset=train,eval_dataset=val,processing_class=processor,training_callback=callback,seed=1702)
    trainables=tree_flatten(model.trainable_parameters())
    assert all('language_model.' in name and ('lora_a' in name or 'lora_b' in name or 'lora_A' in name or 'lora_B' in name) for name,_ in trainables), [name for name,_ in trainables]
    evidence=[]
    for split,dataset,source_rows in [('train',trainer.train_dataset,train),('validation',trainer.eval_dataset,val)]:
        for index in range(len(source_rows)):
            item=dataset[index];ids=np.asarray(item['input_ids']).reshape(-1);mask=np.asarray(item['completion_mask']).reshape(-1)
            if len(ids)>args.max_seq_length: raise ValueError(f'Would truncate {split}/{index}: {len(ids)} tokens')
            count=int(mask.sum());image_id=getattr(model.config,'image_token_id',151655)
            vision=int((ids==image_id).sum())
            if count<=0 or count>=len(ids) or vision<=0 or np.any(mask[ids==image_id]): raise ValueError('Invalid completion/image masking')
            completion=processor.tokenizer.decode(ids[mask.astype(bool)].tolist(),skip_special_tokens=True).strip()
            expected=source_rows[index]['messages'][-1]['content']
            if completion!=expected: raise ValueError('Completion mask does not match the intended JSON answer')
            evidence.append({'split':split,'id':source_rows[index]['id'],'tokens':len(ids),'supervisedTokens':count,'imageTokens':vision})
    summary={'status':'passed','trainSamples':len(train),'validationSamples':len(val),'targets':targets,'trainableParameters':sum(v.size for _,v in trainables),'visionFrozen':True,'baseFrozen':True,'config':dataclasses.asdict(config),'preprocessing':evidence,'maxObservedTokens':max(x['tokens'] for x in evidence),'memoryAtStart':initial_memory,'memory':memory(),'loadAndPreprocessSeconds':time.monotonic()-start,'versions':{x:importlib.metadata.version(x) for x in ('mlx','mlx-vlm','transformers','datasets','psutil')},'pythonPrefix':sys.prefix}
    write(args.out/'preflight.json',summary)
    return model,processor,trainer,callback


def main(args):
    args.out.mkdir(parents=True,exist_ok=True)
    started=time.monotonic()
    model,processor,trainer,callback=prepare(args)
    print('PREFLIGHT PASSED',json.dumps(memory()),flush=True)
    if args.mode=='preflight': return
    if args.mode=='verify':
        if not args.adapter: raise ValueError('--adapter required for fresh-process reload verification')
        saved=mx.load(str(args.adapter/'adapters.safetensors'))
        current=dict(tree_flatten(model.trainable_parameters()))
        if not saved or not all(name in current and np.array_equal(np.array(value),np.array(current[name])) for name,value in saved.items()): raise ValueError('Reloaded adapter differs from checkpoint')
        evaluation=trainer.evaluate()
        write(args.out/'reload-verification.json',{'status':'passed','loadedTensors':len(saved),'validation':evaluation,'memory':memory(),'freshProcessPID':os.getpid()})
        print('FRESH PROCESS ADAPTER RELOAD VERIFIED',evaluation,flush=True)
        return
    trainables=tree_flatten(model.trainable_parameters())
    before={name:np.array(value) for name,value in trainables}
    initial=trainer.evaluate(); write(args.out/'validation-before.json',initial)
    print('INITIAL VALIDATION',initial,flush=True)
    try: result=trainer.train()
    except Exception as error:
        write(args.out/'failure.json',{'error':str(error),'memory':memory(),'seconds':time.monotonic()-started})
        raise
    delta={name:float(np.linalg.norm(np.array(value)-before[name])) for name,value in tree_flatten(model.trainable_parameters())}
    if not any(v>0 for v in delta.values()): raise ValueError('Adapter parameters did not change')
    final=trainer.evaluate()
    base=json.loads((args.out/'base-fingerprint.json').read_text())
    weights=args.out/'adapter/adapters.safetensors'
    write(args.out/'adapter/manifest.json',{'name':'Phos operation LoRA experimental','baseRepo':base['repo'],'baseRevision':base['revision'],'baseConfigSHA256':base['files']['config.json'],'adapterSHA256':hashlib.sha256(weights.read_bytes()).hexdigest(),'adapterConfigSHA256':hashlib.sha256((weights.parent/'adapter_config.json').read_bytes()).hexdigest(),'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT,'schemaVersion':'phos-parameter-plan-v2','dataHashes':json.loads((args.out/'validation-coverage.json').read_text())['dataHashes'],'experimental':True,'resumeSemantics':'adapter warm start only; optimizer/RNG not saved'})
    write(args.out/'summary.json' ,{'status':'trained','before':initial,'after':final,'training':result,'parameterDeltaNorms':delta,'memory':memory(),'seconds':time.monotonic()-started,'productionModelModified':False,'adapterDeployed':False})
    print('PILOT COMPLETED',json.dumps({'validationBefore':initial.get('val_loss'),'validationAfter':final.get('val_loss'),'memory':memory()}),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('mode',choices=('preflight','train','verify'));p.add_argument('--model',type=Path,required=True);p.add_argument('--data',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--adapter',type=Path);p.add_argument('--iters',type=int,default=100);p.add_argument('--layers',type=int,default=4);p.add_argument('--rank',type=int,default=8);p.add_argument('--learning-rate',type=float,default=3e-5);p.add_argument('--max-seq-length',type=int,default=3072);p.add_argument('--steps-per-eval',type=int,default=200);p.add_argument('--steps-per-save',type=int,default=100);p.add_argument('--max-swap-growth-mb',type=int,default=3072);p.add_argument('--min-available-gb',type=float,default=1.0)
    args=p.parse_args();args.model=args.model.resolve();args.data=args.data.resolve();args.out=args.out.resolve()
    try: main(args)
    except BaseException as error:
        write(args.out/'failure.json',{'error':str(error),'type':type(error).__name__,'memory':memory()});raise
