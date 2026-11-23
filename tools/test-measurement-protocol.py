"""Synthetic pairing, load, scope and confidence regressions for manual gates."""
import copy
import random
import unittest
from measurement_protocol import summarize,hygiene


def corpus(effect=1., count=30):
    rng=random.Random(212);groups=[]
    for cycle in range(count):
        load=1+rng.random()*2
        drift=1+rng.uniform(-.02,.02)
        group=[]
        for i,mode in enumerate(['A','B','B','A']):
            ns=10*load*drift**i*(effect if mode=='A' else 1)*rng.uniform(.995,1.005)
            group.append(dict(mode=mode,position=i,digest='a'*64,ns_per_pixel=ns,
                control_before_ns=10*load,control_after_ns=10*load*drift,
                hygiene={'accepted':cycle%7!=0,'reasons':['injected load'] if cycle%7==0 else []}))
        groups.append(group)
    return groups


class ProtocolTests(unittest.TestCase):
    def test_detect_twenty_percent_slowdown(self):
        result=summarize(corpus(1.2));self.assertEqual(result['effect'],'regression')
        self.assertGreater(result['bootstrap_95'][0],1.1)
    def test_no_change_under_load_is_inconclusive(self):
        self.assertEqual(summarize(corpus())['effect'],'inconclusive')
    def test_improvement(self):self.assertEqual(summarize(corpus(.8))['effect'],'improvement')
    def test_small_effect_is_not_promoted(self):self.assertEqual(summarize(corpus(1.05))['effect'],'inconclusive')
    def test_insufficient_hygiene_is_pending(self):
        result=summarize(corpus(.8,10),target=5)
        self.assertEqual(result['classification'],'noisy');self.assertEqual(result['target_status'],'pending')
    def test_conclusive_over_target_fails(self):self.assertEqual(summarize(corpus(1.5),target=1.1)['target_status'],'fail')
    def test_borderline_target_is_pending(self):self.assertEqual(summarize(corpus(),target=1.)['target_status'],'pending')
    def test_rejected_rows_are_counted(self):self.assertEqual(summarize(corpus())['rejected_cycles'],5)
    def test_full_result_identity(self):
        groups=corpus();groups[0][0]['digest']='b'*64
        with self.assertRaises(ValueError):summarize(groups)
    def test_abba_order(self):
        groups=corpus();groups[0][1]['mode']='A'
        with self.assertRaises(ValueError):summarize(groups)
    def test_hygiene(self):
        before=dict(cpu=5,frequency_khz='3000000',loadavg='1 1 1',governor='powersave',power=None,
                    siblings='5,11',cpu_ticks='cpu11 1 0 0 100 0 0 0 0')
        after=copy.deepcopy(before);after['cpu_ticks']='cpu11 1 0 0 110 0 0 0 0'
        row=dict(before=before,after=after)
        self.assertTrue(hygiene(row)['accepted'])
        after['frequency_khz']='3500000';self.assertFalse(hygiene(row)['accepted'])
        after['frequency_khz']='3000000';after['loadavg']='9 1 1';self.assertFalse(hygiene(row)['accepted'])
        after['loadavg']='1 1 1';after['cpu_ticks']='cpu11 2 0 0 110 0 0 0 0'
        self.assertFalse(hygiene(row)['accepted'])


if __name__=='__main__':unittest.main()
