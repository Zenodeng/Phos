#!/usr/bin/env python3
"""Small FiveK research-only acquisition and production-rendered fit experiment."""
import argparse,concurrent.futures,hashlib,importlib.util,json,random,re,time,urllib.request
from pathlib import Path
spec=importlib.util.spec_from_file_location('p01',Path(__file__).with_name('photo_ai_p01.py'));p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p);w=p.w
BASE='https://data.csail.mit.edu/graphics/fivek/'

def collect(a):
    out=a.root/'pairs';out.mkdir(exist_ok=True);evidence=out/'evidence';evidence.mkdir(exist_ok=True)
    for name in ('LicenseAdobe.txt','LicenseAdobeMIT.txt','filesAdobe.txt','filesAdobeMIT.txt'):
        path=evidence/name
        if not path.exists():path.write_bytes(p.fetch(BASE+'legal/'+name,32*1024**2))
    page=evidence/'index.html'
    if not page.exists():page.write_bytes(p.fetch(BASE,8*1024**2))
    names=sorted(set(re.findall(r'img/dng/([^"<>]+)',page.read_text())));random.Random(1810).shuffle(names)
    names=names[:a.count];rows=[];errors=[]
    def one(name):
        try:
            identifier=Path(name).stem;folder=out/identifier;folder.mkdir(exist_ok=True);paths={};urls={}
            for kind,relative in [('source','img/dng/'+name),('target','img/tiff16_c/'+identifier+'.tif')]:
                dest=folder/Path(relative).name;url=BASE+relative
                if not dest.exists():dest.write_bytes(p.fetch(url,64*1024**2))
                paths[kind]=str(dest.resolve());urls[kind]=url
            return {'id':identifier,**paths,'urls':urls,'hashes':{k:w.sha(Path(v)) for k,v in paths.items()},'expert':'C','researchEligible':True,'releaseEligible':False,'licenseFiles':[str(x.relative_to(a.root)) for x in evidence.glob('License*.txt')],'status':'downloaded-unfitted','humanAestheticApproval':False,'usage':'isolated fitting feasibility; no model training; no public weight redistribution claim'},None
        except Exception as e:return None,{'id':name,'error':str(e)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
        for row,error in ex.map(one,names):
            if row:rows.append(row)
            else:errors.append(error)
            w.write(out/'manifest.json',{'sources':rows,'errors':errors,'createdAt':w.now(),'note':'Original DNG + expert-C TIFF, research-only terms preserved. Not human-approved labels.'})
            print('PAIRS',len(rows),'errors',len(errors),flush=True)

def fit(a):
    manifest=w.read(a.root/'pairs/manifest.json');results=[]
    for row in manifest['sources']:
        out=a.root/'pairs'/row['id']/'fit'
        try:
            if not (out/'fit.json').exists():w.worker(a,'fit',{'inputImage':row['source'],'targetImage':row['target'],'maxEvaluations':180},out)
            results.append({'id':row['id'],**w.read(out/'fit.json')})
        except Exception as error:
            results.append({'id':row['id'],'status':'excluded','error':str(error),'trainingEligible':False})
        w.write(a.root/'pairs/fit-report.json',{'results':results,'completed':len(results),'humanReviewStatus':'pending','acceptanceThreshold':0.8,'acceptanceMeasured':False,'trainingEligible':False,'note':'Fit error is not human aesthetic acceptance. CLUT off, global subset only, no alignment compensation.'})
        print('FIT',row['id'],results[-1].get('seconds'),flush=True)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('command',choices=['collect','fit']);parser.add_argument('--root',type=Path,required=True);parser.add_argument('--worker',type=Path,required=True);parser.add_argument('--count',type=int,default=20);a=parser.parse_args();a.root=a.root.resolve();a.worker=a.worker.resolve();globals()[a.command](a)
