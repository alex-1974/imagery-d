import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('canary',Path(__file__).with_name('check-instruction-counts.py'))
canary=importlib.util.module_from_spec(spec);spec.loader.exec_module(canary)

class CanaryTests(unittest.TestCase):
    def test_compressed_trailing_zeros(self):
        self.assertEqual(canary.counters('events: Ir D1mr D1mw DLmr DLmw\nsummary: 100 4 5\n'),
            dict(instructions=100,d1_misses=9,ll_misses=0))
    def test_missing_region_rejected(self):
        with self.assertRaises(ValueError):canary.counters('events: Ir D1mr D1mw DLmr DLmw\nsummary: 0\n')
    def test_regression_rejected(self):
        self.assertTrue(canary.check({'gaussian':{'instructions':200}}, {'gaussian':{'instructions':150}}))
    def test_missing_feature_rejected(self):
        with self.assertRaises(ValueError):canary.check({}, {'gaussian':{'instructions':150}})

if __name__=='__main__':unittest.main()
