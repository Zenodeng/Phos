#!/usr/bin/env python3
"""Contract tests: labels, preserved state, masks, and numerical equivalence."""
import importlib.util,sys,unittest,json,tempfile,hashlib
from photo_ai_protocol import ordered_schema, serialize_target, FINGERPRINT, VERSION
from photo_ai_server import verify_identity
from summarize_photo_ai_p01 import summarize
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('p01',HERE/'photo_ai_p01.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
spec=importlib.util.spec_from_file_location('ev',HERE/'evaluate_photo_ai_p01.py');ev=importlib.util.module_from_spec(spec);spec.loader.exec_module(ev)
class Tests(unittest.TestCase):
 def test_report_keeps_first_attempt_separate_from_retry(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder)/'data';out=Path(folder)/'out';(root/'records').mkdir(parents=True)
   for i in range(3):(root/'records'/('case-'+str(i)+'.json')).write_text(json.dumps({'task':'edit','plan':{'adjustments':{'exposure':.2}}}))
   for name in ('base','incumbent','candidate'):
    destination=out/('evaluation-'+name);destination.mkdir(parents=True)
    results=[{'id':'case-'+str(i),'groupId':'author-'+str(i%2),'firstAttemptSuccess':i==0 or (name=='candidate' and i==1),'postRetrySuccess':True,'seconds':1,'attempts':[{'schemaValid':True}]} for i in range(3)]
    (destination/'results.json').write_text(json.dumps({'completed':3,'requestedCases':3,'results':results,'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT,'firstAttemptSuccess':sum(r['firstAttemptSuccess'] for r in results),'uniquePhotos':3,'uniqueAuthorGroups':2,'retryBudget':1}))
    (destination/'input-fingerprint.json').write_text(json.dumps({'inputs':{},'baseFiles':{},'versions':{}}))
   summarize(root,out)
   report=json.loads((out/'evaluation-summary.json').read_text())
   self.assertEqual(report['variants']['candidate']['success'],2)
   self.assertEqual(report['variants']['base']['success'],1)
   (out/'evaluation-incumbent/input-fingerprint.json').write_text(json.dumps({'inputs':{'changed':'hash'},'baseFiles':{},'versions':{}}))
   with self.assertRaisesRegex(AssertionError,'Different evaluation inputs'):summarize(root,out)
 def test_schema_reordering_preserves_semantics(self):
  schema={'type':'object','properties':{'masks':{'type':'array','items':{'anyOf':[{'type':'object','properties':{'adjustments':{'type':'object'},'kind':{'enum':['linear']}}}]}},'adjustments':{'type':'object'},'summary':{'type':'string'}},'required':['summary','masks','adjustments'],'additionalProperties':False}
  reordered=ordered_schema(schema)
  self.assertEqual(json.dumps(schema,sort_keys=True),json.dumps(reordered,sort_keys=True))
  self.assertEqual(list(reordered['properties']),['summary','adjustments','masks'])
  self.assertEqual(list(reordered['properties']['masks']['items']['anyOf'][0]['properties']),['kind','adjustments'])
 def test_canonicalization_is_value_independent_and_compact(self):
  self.assertEqual(serialize_target({'height':1,'width':.9,'y':0,'x':.05}),'{"x":0.05,"y":0,"width":0.9,"height":1}')
  self.assertEqual(serialize_target({'masks':[],'adjustments':{'contrast':8,'exposure':-.2},'summary':'执行'}),'{"summary":"执行","adjustments":{"exposure":-0.2,"contrast":8},"masks":[]}')
 def test_unknown_future_fields_have_stable_order(self):
  self.assertEqual(serialize_target({'z':0,'a':2}),serialize_target({'a':2,'z':0}))
 def test_nonfinite_training_values_rejected(self):
  with self.assertRaises(ValueError):serialize_target({'exposure':float('nan')})
 def test_app_and_python_share_protocol_identity(self):
  swift=(HERE.parent/'Sources/Phos/LocalPhotoAI.swift').read_text()
  self.assertIn('"'+VERSION+'"',swift);self.assertIn('"'+FINGERPRINT+'"',swift)
 def test_server_rejects_tampered_base_or_unversioned_adapter(self):
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder);model=root/'model';adapter=root/'adapter';model.mkdir();adapter.mkdir()
   (model/'config.json').write_text('{}');(model/'tokenizer.json').write_text('{"version":1}')
   digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
   lock={'repo':'test-pinned','revision':'test-revision','files':{n:digest(model/n) for n in ('config.json','tokenizer.json')}}
   (adapter/'adapters.safetensors').write_bytes(b'test');(adapter/'adapter_config.json').write_text('{}')
   manifest={'baseRepo':lock['repo'],'baseRevision':lock['revision'],'baseConfigSHA256':lock['files']['config.json'],'adapterSHA256':digest(adapter/'adapters.safetensors'),'adapterConfigSHA256':digest(adapter/'adapter_config.json'),'serializationVersion':VERSION,'decoderFingerprint':FINGERPRINT}
   (adapter/'manifest.json').write_text(json.dumps(manifest))
   self.assertEqual(verify_identity(model,adapter,lock)['baseRevision'],lock['revision'])
   (adapter/'adapter_config.json').write_text('{"rank":16}')
   with self.assertRaisesRegex(ValueError,'configuration fingerprint'):verify_identity(model,adapter,lock)
   (adapter/'adapter_config.json').write_text('{}')
   (model/'tokenizer.json').write_text('{"version":2}')
   with self.assertRaisesRegex(ValueError,'Base file'):verify_identity(model,adapter,lock)
   (model/'tokenizer.json').write_text('{"version":1}');del manifest['serializationVersion']
   (adapter/'manifest.json').write_text(json.dumps(manifest))
   with self.assertRaisesRegex(ValueError,'serialization'):verify_identity(model,adapter,lock)
 def test_equivalent_mask_uuid_is_not_semantics(self):
  self.assertTrue(ev.equivalent({'masks':[{'id':'A','name':'old','adjust':{'exposure':.3}}]},{'masks':[{'id':'B','name':'new','adjust':{'exposure':.30000000001}}]}))
 def test_changed_background_not_equivalent(self):
  self.assertFalse(ev.equivalent({'exposure':.4,'masks':[]},{'exposure':.3,'masks':[]}))
 def test_protected_changes_fail_even_if_target_matches(self):
  r={'task':'edit','baseParams':{'temperature':0},'protectedFields':['temperature']}
  s=ev.score(r,{}, {'temperature':1},{'temperature':1},{})
  self.assertFalse(s['success']);self.assertFalse(s['protectedFieldsUnchanged'])
 def test_raw_direction_repair_is_not_first_success(self):
  s=ev.score({'task':'edit','baseParams':{}},{},{},{},{'normalizations':['mask-1']})
  self.assertFalse(s['success'])
 def test_crop_numeric_geometry(self):
  r={'task':'crop','baseParams':{},'crop':{'x':.05,'y':0,'width':.9,'height':1}}
  self.assertTrue(ev.score(r,r['crop'],{},{},{})['success'])
  self.assertFalse(ev.score(r,dict(r['crop'],width=1),{},{},{})['success'])
 def test_varied_signs_and_geometries(self):
  kinds=set();values=set()
  for index in range(4):
   for task,instruction,target in p.templates(index):
    if task=='edit':
     for m in target.get('masks',[]):
      kinds.add(m['kind']);values.add(m['adjustments'].get('exposure'))
      value=m['adjustments'].get('exposure',0)
      self.assertTrue(value>=0 if m['brightness']=='brighten' else value<=0)
  self.assertTrue({'linear','radial','luminanceRange'}<=kinds)
  self.assertTrue(any(v<0 for v in values));self.assertTrue(any(v>0 for v in values))
if __name__=='__main__':unittest.main()
