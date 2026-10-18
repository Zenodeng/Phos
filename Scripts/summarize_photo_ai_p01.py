#!/usr/bin/env python3
"""Paired same-case comparisons; uncertainty resamples author groups, not rows."""
import argparse
import collections
import json
import random
from pathlib import Path


def category(record):
    plan=record.get('plan',{})
    if record['task']=='crop':return 'crop'
    if plan.get('masks'):
        mask=plan['masks'][0]
        return 'mask:'+mask['kind']+':'+mask.get('target','region')
    for key in ('curves','hsl','grading'):
        if plan.get(key):return key
    return 'global' if plan.get('adjustments') else 'refusal/noop'


def interval(values):
    values=sorted(values)
    return [round(values[int(len(values)*q)]*100,2) for q in (.025,.975)]


def summarize(root,out):
    reports={key:json.loads((out/('evaluation-'+key)/'results.json').read_text()) for key in ('base','incumbent','candidate')}
    first=reports['base'];ids=[r['id'] for r in first['results']]
    assert first['completed']==first['requestedCases']
    for report in reports.values():
        assert report['completed']==report['requestedCases']==len(ids)
        assert ids==[r['id'] for r in report['results']]
        assert report['serializationVersion']==first['serializationVersion'] and report['decoderFingerprint']==first['decoderFingerprint']
    fingerprints={k:json.loads((out/('evaluation-'+k)/'input-fingerprint.json').read_text()) for k in reports}
    for key,fp in fingerprints.items():
        assert fp['inputs']==fingerprints['base']['inputs'], 'Different evaluation inputs: '+key
        assert fp['baseFiles']==fingerprints['base']['baseFiles'] and fp['versions']==fingerprints['base']['versions']
    categories={i:category(json.loads((root/'records'/(i+'.json')).read_text())) for i in ids}
    groups=collections.defaultdict(list)
    for index,row in enumerate(first['results']):groups[row['groupId']].append(index)
    groups=list(groups.values());rng=random.Random(1810);boot={k:[] for k in reports};differences=[]
    for _ in range(2000):
        sampled=[index for group in rng.choices(groups,k=len(groups)) for index in group]
        rates={key:sum(report['results'][i]['firstAttemptSuccess'] for i in sampled)/len(sampled) for key,report in reports.items()}
        for key in boot:boot[key].append(rates[key])
        differences.append(rates['candidate']-rates['incumbent'])
    summary={}
    for key,report in reports.items():
        rows=report['results'];elapsed=sorted(r['seconds'] for r in rows);subgroups={}
        for name in sorted(set(categories.values())):
            subset=[r for r in rows if categories[r['id']]==name]
            subgroups[name]={'success':sum(r['firstAttemptSuccess'] for r in subset),'total':len(subset)}
        summary[key]={'success':report['firstAttemptSuccess'],'total':len(rows),'percent':round(report['firstAttemptSuccess']/len(rows)*100,2),'authorBootstrap95Percent':interval(boot[key]),'schemaValid':sum(r['attempts'][0].get('schemaValid',False) for r in rows),'protectedViolationObserved':sum(r['attempts'][0].get('protectedFieldsUnchanged') is False for r in rows),'caseSecondsP50':elapsed[len(elapsed)//2],'caseSecondsP95':elapsed[min(len(elapsed)-1,int(len(elapsed)*.95))],'groups':subgroups,'failures':[r for r in rows if not r['firstAttemptSuccess']]}
    result={'scope':'Controlled instruction following on full development validation; not aesthetic or independent vision acceptance','uniquePhotos':first['uniquePhotos'],'uniqueAuthorGroups':first['uniqueAuthorGroups'],'serializationVersion':first['serializationVersion'],'decoderFingerprint':first['decoderFingerprint'],'sameInputsAndVersions':True,'retries':first['retryBudget'],'candidateMinusIncumbent95PercentagePoints':interval(differences),'variants':summary,'limitations':['Repeated task templates reduce semantic independence even across new photos.','301 validation cases are not the held-out test set.','Timing includes offline renderer and excludes model loading; not production latency.','Protected violation count only covers evaluated rendered states; rejection is not success.','Raw normalization, even if host-corrected, fails first-attempt success.']}
    (out/'evaluation-summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    lines=['# 同权重扩大验证集对照','',f'全部 {len(ids)} 条验证指令，{first["uniquePhotos"]} 张照片、{first["uniqueAuthorGroups"]} 个作者组。相同底模、图片、提示词、schema 语义、序列化文法和渲染器；每例一次生成，不计宿主修正或重试为首次成功。','','| 权重 | 首次严格通过 | JSON/schema 合规 |','|---|---:|---:|']
    for key,value in summary.items():lines.append(f'| {key} | {value["success"]}/{value["total"]} ({value["percent"]}%) | {value["schemaValid"]}/{value["total"]} |')
    lines+=['','| 任务 | base | incumbent | candidate |','|---|---:|---:|---:|']
    for name in sorted(set(categories.values())):
        cells=[f'{summary[k]["groups"][name]["success"]}/{summary[k]["groups"][name]["total"]}' for k in reports]
        lines.append('| '+name+' | '+' | '.join(cells)+' |')
    lines+=['','这些是受控操作结果，不证明审美或任意照片构图能力。正式 test 和图片理解保留集没有用于本次选择。完整错误、按作者分组的 bootstrap 区间和输入指纹见 evaluation-summary.json 与各 evaluation 目录。']
    (out/'扩大评测报告.md').write_text('\n'.join(lines)+'\n')
    print({k:{n:v[n] for n in ('success','total','percent','schemaValid')} for k,v in summary.items()})


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();summarize(a.root.resolve(),a.out.resolve())
