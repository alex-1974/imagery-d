import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('counts',Path(__file__).with_name('check-engine-instructions.py'))
counts=importlib.util.module_from_spec(spec);spec.loader.exec_module(counts)


class FormatTests(unittest.TestCase):
    def test_inclusive_calls_and_name_pool(self):
        text='positions: line\nevents: Ir Dr\nsummary: 30 7\nfn=(1) parent\n1 10 2\ncfn=(2) child\ncalls=1 1\n+1 20 5\nfn=(2)\n1 20 5\n'
        total,functions=counts.function_costs(text)
        self.assertEqual(total,{'Ir':30,'Dr':7})
        self.assertEqual(functions['parent'],{'Ir':30,'Dr':7})
        self.assertEqual(functions['child'],{'Ir':20,'Dr':5})
    def test_sparse_events_and_two_positions(self):
        _,functions=counts.function_costs('positions: instr line\nevents: Ir Dr Dw\nsummary: 5\nfn=fn\n0x10 1 5\n')
        self.assertEqual(functions['fn'],{'Ir':5})
    def test_empty_region_rejected(self):
        with self.assertRaises(ValueError):counts.function_costs('events: Ir\nsummary: 0\n')
    def test_missing_boundaries_rejected(self):
        with self.assertRaises(ValueError):counts.phases('events: Ir\nsummary: 10\nfn=x\n1 10\n')


if __name__=='__main__':unittest.main()
