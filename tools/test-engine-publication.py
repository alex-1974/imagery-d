"""Coverage and admission laws for incremental publication receipts."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('publication',Path(__file__).with_name('qualify-engine-publication.py'))
publication=importlib.util.module_from_spec(spec);spec.loader.exec_module(publication)
POLICY=dict(operators=['gaussian','gradient'],eligible_modes=['cold32-view','warm-view'],minimum_cycles=15)
CASES={f'{f}/{m}' for f in POLICY['operators'] for m in POLICY['eligible_modes']}


def complete():
    return dict(instrumented=True,numerical_preflight=True,minimum_cycles=15,
        results={k:dict(accepted_cycles=15) for k in CASES},gates=[dict(status='pass') for k in CASES])


class AdmissionTests(unittest.TestCase):
    def test_incremental_first_operator_is_pending(self):
        report=complete();report['results']={k:v for k,v in report['results'].items() if k.startswith('gaussian/')};report['gates']=report['gates'][:2]
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')
    def test_requested_subset_is_not_full_policy(self):
        report=complete();subset={k for k in CASES if k.startswith('gaussian/')};report['results']={k:report['results'][k] for k in subset};report['gates']=report['gates'][:2]
        self.assertEqual(publication.publication_status(report,POLICY,subset),'pending')
    def test_full_qualified_policy_passes(self):
        self.assertEqual(publication.publication_status(complete(),POLICY,CASES),'pass')
    def test_fourteen_cycles_cannot_pass(self):
        report=complete();report['results'][sorted(CASES)[0]]['accepted_cycles']=14
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')
    def test_explicit_twenty_cycles_are_respected(self):
        report=complete();report['minimum_cycles']=20
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')
    def test_missing_gate_cannot_pass(self):
        report=complete();report['gates'].pop()
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')
    def test_conclusive_failure_is_visible_before_full_collection(self):
        report=complete();report['results']={};report['gates']=[dict(status='fail')]
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'fail')
    def test_ordinary_time_never_admits_instrumented_phases(self):
        report=complete();report['instrumented']=False
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'measured_without_phase_admission')
        report['results']={}
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')
    def test_numerical_preflight_required(self):
        report=complete();report['numerical_preflight']=False
        self.assertEqual(publication.publication_status(report,POLICY,CASES),'pending')


if __name__=='__main__':unittest.main()
