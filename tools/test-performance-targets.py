"""Regression tests for evidence-gate rejection of incomplete or fake receipts."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('targets',Path(__file__).with_name('check-performance-targets.py'))
targets=importlib.util.module_from_spec(spec);spec.loader.exec_module(targets)

class GateTests(unittest.TestCase):
    def setUp(self):
        self.policy={'targets':{'gaussian':{'maximum_ratio':5}}}
        self.report=dict(schema=1,numerical_preflight=True,available_workers=4,
            expected_steady_operators=['gaussian'],expected_steady_modes=['warm'],expected_scaling_operators=['gaussian'],
            observations=[dict(operator='gaussian',mode='warm',size=1024,domain='scalar',ns_per_pixel=3.,checksum=1.,
                steady_state=True,gc_bytes=0,computed_tiles=16,target_eligible=True,reference={'ns_per_pixel':1.},comparison_contract='checked')],
            scaling=[dict(operator='gaussian',workers=n,ns_per_pixel=3./n,digest='a'*64,gc_bytes=0,computed_tiles=16) for n in [1,2,4]])
    def check(self):return targets.check(self.report,self.policy)
    def test_complete(self):self.assertEqual(self.check()[1:],([],[]))
    def test_wrong_target_scope(self):
        self.policy['targets']['gaussian']['eligible_modes']=['prepared']
        with self.assertRaises(ValueError):self.check()
    def test_diagnostic_ratio_does_not_replace_target(self):
        row=copy.deepcopy(self.report['observations'][0]);row.update(mode='cold-engine',target_eligible=False,ns_per_pixel=99.)
        self.report['observations'].append(row)
        self.assertEqual(self.check()[1:],([],[]))
        self.assertEqual(self.check()[0][-1]['status'],'diagnostic')
    def test_cache_hits_do_not_qualify(self):
        self.report['observations'][0]['computed_tiles']=0;self.assertTrue(self.check()[2])
    def test_warm_allocation(self):
        self.report['observations'][0]['gc_bytes']=8;self.assertTrue(self.check()[2])
    def test_fixed_target_not_redefined(self):
        self.report['observations'][0]['ns_per_pixel']=9;self.assertTrue(self.check()[1])
    def test_missing_precision_mode(self):
        self.report['expected_steady_modes'].append('planar');self.assertTrue(self.check()[2])
    def test_no_numerical_preflight(self):
        self.report['numerical_preflight']=False
        with self.assertRaises(ValueError):self.check()
    def test_duplicate_observation(self):
        self.report['observations']*=2
        with self.assertRaises(ValueError):self.check()
    def test_missing_scaling_count(self):
        self.report['scaling'].pop()
        with self.assertRaises(ValueError):self.check()
    def test_digest_mismatch(self):
        self.report['scaling'][0]['digest']='b'*64
        with self.assertRaises(ValueError):self.check()
    def test_worker_allocation(self):
        self.report['scaling'][1]['gc_bytes']=4;self.assertTrue(self.check()[2])
    def test_missing_scaling_family(self):
        self.report['expected_scaling_operators'].append('ridge');self.assertTrue(self.check()[1])
    def test_no_steady_coverage(self):
        self.report['observations']=[];self.assertTrue(self.check()[1]);self.assertTrue(self.check()[2])

if __name__=='__main__':unittest.main()
