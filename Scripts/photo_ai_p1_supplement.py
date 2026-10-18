#!/usr/bin/env python3
"""Versioned P1 supplement: varied values, geometry and existing state.

Uses only the already assigned training authors/photos. All added answers are
known operations verified by the real renderer, never aesthetic ground truth.
"""
import argparse
import collections
import copy
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path
from types import SimpleNamespace
from PIL import Image, ImageOps
from photo_ai_protocol import serialize_target, VERSION, FINGERPRINT


def main(a):
    import jsonschema
    spec=importlib.util.spec_from_file_location('p01',Path(__file__).with_name('photo_ai_p01.py'))
    p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p);w=p.w
    a.original=a.original.resolve();a.out=a.out.resolve();a.worker=a.worker.resolve()
    if (a.out/'supplement-report.json').exists():raise ValueError('Use a fresh dataset version')
    (a.out/'records').mkdir(parents=True,exist_ok=True);(a.out/'sft').mkdir(exist_ok=True)
    for path in (a.original/'records').glob('*.json'):
        record=w.read(path);record['renderPath']=str((a.original/record['renderPath']).resolve())
        w.write(a.out/'records'/path.name,record)
    splits={name:[json.loads(x) for x in (a.original/'sft'/(name+'.jsonl')).read_text().splitlines()] for name in ('train','validation','test')}
    sources=[json.loads(x) for x in (a.original/'dataset_manifest.jsonl').read_text().splitlines()]
    selected=sorted([s for s in sources if s['split']=='train'],key=lambda s:s['id'])
    defaults=w.read(a.original/'protocol/defaults.json');accepted=[];rejected=[]
    for i,source in enumerate(selected):
        for j in range(2):
            n=i*2+j;mode=n%8;ev=round(((n%15)-7)*.05,2) or .1
            base=copy.deepcopy(defaults)
            base.update(exposure=round(((i%9)-4)*.1,2),grain=i%17,temperature=(i%23)-11,tint=(i%9)-4)
            plan={'summary':'执行指定操作。','adjustments':{},'masks':[]};allowed=set();task='edit'
            if mode==0:
                contrast=(n%31)-15;plan['adjustments']={'exposure':ev,'contrast':contrast};allowed={'exposure','contrast'}
                instruction=f'整体曝光设置为{ev} EV，对比度设置为{contrast}；其他参数保持不变，不要新增蒙版。'
            elif mode==1:
                temp=(n%39)-19;tint=(n%17)-8;plan['adjustments']={'temperature':temp,'tint':tint};allowed={'temperature','tint'}
                instruction=f'色温相对值设置为{temp}，色调设置为{tint}；其他参数保持不变，不要新增蒙版。'
            elif mode==2:
                hue=(n%31)-15;sat=-(n%29)-1;plan['hsl']={'green':{'hue':hue,'sat':sat}};allowed={'hsl'}
                instruction=f'仅用 HSL 将绿色色相设置为{hue}、饱和度设置为{sat}；其他参数保持不变，不要新增蒙版。'
            elif mode==3:
                middle=round(.43+(n%15)*.01,2);plan['curves']={'luma':[[0,0],[.25,.25],[.5,middle],[.75,.75],[1,1]]};allowed={'lumaCurve'}
                instruction=f'仅将亮度曲线五个锚点设置为(0,0)、(0.25,0.25)、(0.5,{middle})、(0.75,0.75)、(1,1)；其他参数保持不变，不要新增蒙版。'
            elif mode in (4,5):
                local=round((1+(n//8)%8)*.05,2)*(1 if (n//64)%2 else -1);bright='brighten' if local>0 else 'darken';verb='提亮' if local>0 else '压暗'
                x=round(.2+(n%21)*.02,2);y=round(.25+((n//8)%16)*.02,2)
                if mode==4:
                    geometry={'x0':x,'y0':.2,'x1':.8,'y1':.8,'feather':round(.3+(n%5)*.1,2)};kind='linear'
                    instruction=f'只创建线性渐变蒙版{verb}选区，起点({x},0.2)，终点(0.8,0.8)，羽化{geometry["feather"]}，局部曝光设置为{local} EV；全局参数保持不变。'
                else:
                    geometry={'x0':x,'y0':y,'radiusX':round(.15+(n%9)*.02,2),'radiusY':.2,'feather':.5};kind='radial'
                    instruction=f'只创建径向蒙版{verb}选区，中心({x},{y})，横半径{geometry["radiusX"]}、纵半径0.2、羽化0.5，局部曝光设置为{local} EV；全局参数保持不变。'
                plan['masks']=[{'kind':kind,'target':'region','brightness':bright,'geometry':geometry,'adjustments':{'exposure':local}}]
            elif mode==6:
                task='crop';percent=1+(n//8)%12;t=round(percent/100,2);plan={'x':t,'y':0,'width':round(1-2*t,2),'height':1}
                instruction=f'仅裁去左右各{percent}%，保留完整高度，不要旋转。'
            else:
                sat=-(1+(n//8)%24);plan['adjustments']={'exposure':ev};plan['hsl']={'blue':{'sat':sat}};allowed={'exposure','hsl'}
                instruction=f'整体曝光设置为{ev} EV，同时用 HSL 将蓝色饱和度设置为{sat}；其他参数保持不变，不要新增蒙版。'
            identifier=source['id']+'-varied-'+str(j)
            record={'id':identifier,'version':'phos-dataset-v3','sourceId':source['id'],'groupId':source['groupId'],'split':'train','task':task,'instruction':instruction,'baseParams':base,'inputImage':str((a.original/source['path']).resolve()),'crop' if task=='crop' else 'plan':plan,'schemaVersion':'phos-parameter-plan-v2','protectedFields':sorted(set(base)-allowed-{'masks'} if task=='edit' else set()),'labelType':'controlled-operation','review':{'decision':'pending','notes':'Operation correctness automatically verified; no human aesthetic approval'},'provenance':'Known operation, training partition only; real Phos renderer','confidence':None,'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT}
            record['baseStateId']=hashlib.sha256(json.dumps(base,sort_keys=True,separators=(',',':')).encode()).hexdigest();record['operationId']=identifier
            dest=a.out/'renders'/identifier
            try:
                w.worker(a,'protocol',record,dest/'protocol');schema=w.read(dest/'protocol'/('crop-schema.json' if task=='crop' else 'edit-schema.json'));jsonschema.validate(plan,schema)
                w.worker(a,'render',record,dest);report=w.read(dest/'render.json')
                if report.get('normalizations') or report.get('directionError') or report.get('rawDirectionError'):raise ValueError('Direction or normalization failed')
                actual=w.read(dest/'after-params.json')
                if any(base[k]!=actual[k] for k in record['protectedFields']):raise ValueError('Protected field changed')
                with Image.open(dest/'before.jpg') as image:ImageOps.contain(image.convert('RGB'),(336,336)).save(dest/'model-input.jpg',quality=95)
                record.update(renderPath=str(dest.relative_to(a.out)),imageSHA256=w.sha(Path(record['inputImage'])),quality={'status':'synthetic_verified','humanAestheticApproval':False,'rawDirectionCorrect':True,'protectedFieldsUnchanged':True})
                w.write(a.out/'records'/(identifier+'.json'),record)
                splits['train'].append({'id':identifier,'sourceId':source['id'],'groupId':source['groupId'],'task':task,'images':[str(dest/'model-input.jpg')],'messages':[{'role':'user','content':(dest/'protocol/prompt.txt').read_text()},{'role':'assistant','content':serialize_target(plan)}],'labelType':'synthetic_verified','promptVariant':'production-shared-builder-v2'})
                accepted.append(identifier)
            except Exception as error:rejected.append({'id':identifier,'error':str(error)[:500]})
            if n%25==0:print('SUPPLEMENT',n,'accepted',len(accepted),'rejected',len(rejected),flush=True)
    for split,rows in splits.items():(a.out/'sft'/(split+'.jsonl')).write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
    proof={'counts':{k:len(v) for k,v in splits.items()},'added':len(accepted),'rejected':rejected,'uniqueTrainingAnswersBefore':len({r['messages'][-1]['content'] for r in splits['train'] if r['id'] not in set(accepted)}),'uniqueTrainingAnswersAfter':len({r['messages'][-1]['content'] for r in splits['train']}),'photos':len(selected),'scope':'Additional controlled instructions and values; no new aesthetic supervision, no P2 retraining','originalRoot':str(a.original),'workerSHA256':w.sha(a.worker),'preservedValidationAndTest':all((a.out/'sft'/(k+'.jsonl')).read_bytes()==(a.original/'sft'/(k+'.jsonl')).read_bytes() for k in ('validation','test'))}
    for name in ('dataset_manifest.jsonl','split-manifest.json'):
        shutil.copy2(a.original/name,a.out/name)
    for name in ('assets','sources','protocol'):
        (a.out/name).symlink_to(a.original/name,target_is_directory=True)
    summary=w.read(a.original/'dataset-report.json')
    summary.update(counts=proof['counts'],records=sum(proof['counts'].values()),dataVersion='phos-dataset-v3',supplementAdded=len(accepted))
    w.write(a.out/'dataset-report.json',summary)
    (a.out/'baseline').mkdir(exist_ok=True)
    shutil.copy2(a.original/'baseline/model-fingerprint.json',a.out/'baseline/model-fingerprint.json')
    shutil.copytree(a.original/'baseline/incumbent-adapter',a.out/'baseline/incumbent-adapter',dirs_exist_ok=True)
    shutil.copytree(a.original/'worker-final',a.out/'worker-final',dirs_exist_ok=True)
    w.write(a.out/'supplement-report.json',proof);print(proof,flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--worker',type=Path,required=True);main(p.parse_args())
