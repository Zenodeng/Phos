#!/usr/bin/env python3
"""Dataset leakage, release eligibility, approval integrity and renderer checks."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('workbench',Path(__file__).with_name('photo_ai_workbench.py'))
w=importlib.util.module_from_spec(spec); spec.loader.exec_module(w)


class DatasetContractTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.args=argparse.Namespace(root=self.root,purpose='release')
        (self.root/'assets').mkdir()
        (self.root/'assets/input.jpg').write_bytes(b'fixture-image')
        self.source={'id':'source','path':'assets/input.jpg','status':'downloaded','sha256':w.sha(self.root/'assets/input.jpg'),'releaseEligible':True,'researchEligible':True}
        self.record={'version':w.VERSION,'id':'sample','task':'edit','sourceId':'source','groupId':'group','split':'train','instruction':'No changes','imageSHA256':self.source['sha256'],'renderPath':'renders/sample','plan':{'summary':'none','adjustments':{},'masks':[]},'review':{'decision':'pending'}}
        self.render=self.root/'renders/sample'; self.render.mkdir(parents=True)
        (self.render/'after.jpg').write_bytes(b'reviewed-pixels')
        (self.render/'before.jpg').write_bytes(b'input-pixels')
        w.write(self.render/'render.json',{'status':'rendered'})
        w.write(self.render/'before-params.json',{})
        frozen=self.root/'baseline/frozen/source/Sources/Phos'; frozen.mkdir(parents=True)
        shutil.copy2(w.REPO/'Sources/Phos/LocalPhotoAI.swift',frozen/'LocalPhotoAI.swift')
        self.save()

    def tearDown(self): self.temp.cleanup()

    def save(self):
        w.write(self.root/'sources/manifest.json',{'sources':[self.source]})
        w.write(self.root/'records/sample.json',self.record)

    def approve(self):
        self.record['review']={'decision':'approved','renderSHA256':w.sha(self.render/'after.jpg'),'recordFingerprint':w.fingerprint(self.record)}
        self.save()

    def exported(self):
        w.export(self.args)
        return w.read(self.root/'exports'/self.args.purpose/'manifest.json')['exported']

    def test_pending_is_not_training_data(self): self.assertEqual(self.exported(),0)

    def test_approved_test_record_is_never_training_data(self):
        self.record['split']='test'; self.approve(); self.assertEqual(self.exported(),0)

    def test_restricted_data_cannot_enter_release_export(self):
        self.source['releaseEligible']=False; self.approve()
        self.assertEqual(self.exported(),0)
        self.args.purpose='research'; self.assertEqual(self.exported(),1)

    def test_known_approved_train_record_is_exported(self):
        self.approve(); self.assertEqual(self.exported(),1)

    def test_unknown_research_rights_are_not_assumed(self):
        self.source['researchEligible']=False; self.source['releaseEligible']=False; self.approve()
        self.args.purpose='research'; self.assertEqual(self.exported(),0)

    def test_changed_instruction_invalidates_approval(self):
        self.approve(); self.record['instruction']='Different target'; self.save()
        with self.assertRaises(ValueError): w.validate(self.args)

    def test_changed_pixels_invalidates_approval(self):
        self.approve(); (self.render/'after.jpg').write_bytes(b'changed')
        with self.assertRaises(ValueError): w.validate(self.args)

    def test_identical_image_cannot_cross_splits(self):
        other=copy.deepcopy(self.record); other.update(id='other',groupId='different-name',split='test')
        w.write(self.root/'records/other.json',other)
        with self.assertRaises(ValueError): w.validate(self.args)

    def test_traversal_is_rejected(self):
        with self.assertRaises(ValueError): w.inside(self.root,'../outside')


def integration(root,worker):
    args=argparse.Namespace(root=root,worker=worker)
    original=w.read(root/'records/probe-01-global.json')
    with tempfile.TemporaryDirectory() as directory:
        out=Path(directory)
        source=next(x for x in w.read(root/'sources/manifest.json')['sources'] if x['id']==original['sourceId'])
        request=dict(original,inputImage=str(root/source['path']))
        w.worker(args,'render',request,out/'first')
        w.worker(args,'render',request,out/'second')
        assert w.read(out/'first/after-params.json')==w.read(out/'second/after-params.json')
        assert w.sha(out/'first/after.jpg')==w.sha(out/'second/after.jpg')
        invalid=dict(request,crop={'x':.9,'y':0,'width':.8,'height':1})
        try: w.worker(args,'render',invalid,out/'invalid')
        except RuntimeError: pass
        else: raise AssertionError('Out-of-bounds crop accepted')
        assert not list((root/'assets').glob('*.rawforge.json'))
    print('PASS production renderer deterministic replay, invalid crop rejection, source sidecar preservation')


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--root',type=Path,required=True); parser.add_argument('--worker',type=Path,required=True); options=parser.parse_args()
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(DatasetContractTests)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful(): raise SystemExit(1)
    integration(options.root.resolve(),options.worker.resolve())
