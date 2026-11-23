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

class EngineGateTests(unittest.TestCase):
    def setUp(self):
        summary=dict(accepted_cycles=15,ratio=1.5,bootstrap_95=[1.4,1.6],prepared_gc_bytes=0)
        self.policy=dict(targets={'canny':{'maximum_ratio':5}},engine=dict(size=1024,
            operators={'gaussian':{'maximum_ratio':3}},eligible_modes=['cold64','cold32','warm'],
            phase_ceilings_ns_per_pixel={'source':10}))
        self.report=dict(size=1024,numerical_preflight=True,comparison_contract='strict-float64-final-float32/full-frame-v1',
            results=dict(gaussian={m:copy.deepcopy(summary) for m in ['cold64','cold32','warm']},canny={'canny-d':copy.deepcopy(summary)}),
            profile_results={'gaussian':{'cold64':{'phases':{'source':dict(samples=15,median=5,bootstrap_95=[4,6])}}}},
            canny={'portable':{'validation':{'cases':120,'mismatched_pixels':0}}})
        self.report['canny']['native']=copy.deepcopy(self.report['canny']['portable'])
        self.report['results']['canny:native']=copy.deepcopy(self.report['results']['canny'])
    def check(self):return targets.check_engine_paths(self.report,self.policy)
    def test_complete(self):self.assertTrue(all(g['status']=='pass' for g in self.check()))
    def test_loosened_hygiene_rejected(self):
        self.policy['engine']['hygiene_limits']={'sibling_busy_fraction':.05}
        self.report['hygiene']={'sibling_busy_fraction':.5}
        self.assertEqual(self.check()[0]['status'],'fail')
    def test_missing_mode_pending(self):
        del self.report['results']['gaussian']['warm'];self.assertIn('pending',[g['status'] for g in self.check()])
    def test_noisy_never_passes(self):
        self.report['results']['gaussian']['cold64']['accepted_cycles']=3
        self.assertEqual(self.check()[0]['status'],'pending')
    def test_conclusive_engine_regression(self):
        self.report['results']['gaussian']['cold64'].update(ratio=4,bootstrap_95=[3.9,4.1])
        self.assertEqual(self.check()[0]['status'],'fail')
    def test_wrong_arithmetic_pending(self):
        self.report['comparison_contract']='approximate Gaussian32'
        self.assertEqual(self.check()[0]['status'],'pending')
    def test_missing_independent_oracle_pending(self):
        self.report['numerical_preflight']=False;self.assertEqual(self.check()[0]['status'],'pending')
    def test_missing_profile_pending(self):
        self.report['profile_results']={};self.assertIn('pending',[g['status'] for g in self.check()])
    def test_phase_regression(self):
        self.report['profile_results']['gaussian']['cold64']['phases']['source'].update(median=12,bootstrap_95=[11,13])
        self.assertIn('fail',[g['status'] for g in self.check()])
    def test_mismatched_canny_rejected(self):
        self.report['canny']['portable']['validation']['mismatched_pixels']=1
        self.assertIn('fail',[g['status'] for g in self.check()])
    def test_warm_allocation_rejected(self):
        self.report['results']['gaussian']['warm']['prepared_gc_bytes']=1
        self.assertIn('fail',[g['status'] for g in self.check()])

class WindowGateTests(unittest.TestCase):
    def setUp(self):
        self.policy={"windows":{"ratios":{"pathOpening":.2},"normalization_absolute_ns_per_pixel":78,"hygiene_limits":{}}}
        self.report=dict(numerical_preflight=True,size=1024,comparison_contract='float32-input-float64-statistics/prepared-kernel-v1',
            results={'pathOpening':dict(accepted_cycles=15,ratio=.1,bootstrap_95=[.09,.11])})
        for r in [1,3,7,15,31]:
            self.report['results'][f'normalization-r{r}']={'absolute_native_ns_per_pixel':dict(samples=15,median=40,bootstrap_95=[38,42])}
    def check(self):return targets.check_window_paths(self.report,self.policy)
    def test_complete(self):self.assertTrue(all(g['status']=='pass' for g in self.check()))
    def test_missing_before_after_pending(self):
        del self.report['results']['pathOpening'];self.assertEqual(self.check()[0]['status'],'pending')
    def test_missing_radius_pending(self):
        del self.report['results']['normalization-r31'];self.assertEqual(self.check()[-1]['status'],'pending')
    def test_absolute_budget_not_redefined(self):
        self.report['results']['normalization-r31']['absolute_native_ns_per_pixel'].update(median=100,bootstrap_95=[95,105])
        self.assertEqual(self.check()[-1]['status'],'fail')
    def test_wrong_input_scope_pending(self):
        self.report['comparison_contract']='float64 input';self.assertEqual(self.check()[0]['status'],'pending')

if __name__=='__main__':unittest.main()
