"""Combine disjoint paired cells, retaining per-cell CPU/session provenance.

Existing cells cannot be replaced by a preferred rerun. All sessions must use
identical binaries, numerical validation, control binary and hygiene policy.
"""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('reports',nargs='+',type=Path)
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    result=None;sessions=[]
    for path in args.reports:
        report=json.loads(path.read_text())
        if 'baseline_source' in report:raise ValueError('Only unchanged-source ISA sessions can be combined')
        if result is None:
            result={k:v for k,v in report.items() if k not in ['results','status','coverage','sessions']}
            result['results']={}
        for key in ['size','compiler','cpu_model','binary_source','builds','hygiene','control_build','control_validation','contract']:
            if report[key]!=result[key]:raise ValueError('Session contract differs: '+key)
        session=dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            cpu=report['cpu'],source=report['source'],tracked_dirty=report['tracked_dirty'],
            status=report.get('status','interrupted'),observer_affinity=report['observer_affinity'],
            maximum_collection_seconds_per_setting=report.get('maximum_collection_seconds_per_setting'))
        if 'interruption' in report:session['interruption']=report['interruption']
        sessions.append(session)
        for feature,variants in report['results'].items():
            selected=result['results'].setdefault(feature,{})
            for target,summary in variants.items():
                if target in selected:raise ValueError('Overlapping cells cannot be cherry-picked')
                selected[target]=dict(summary,measurement_cpu=report['cpu'],session=len(sessions)-1)
    from importlib.util import spec_from_file_location,module_from_spec
    spec=spec_from_file_location('codegen',Path(__file__).with_name('qualify-codegen.py'))
    codegen=module_from_spec(spec);spec.loader.exec_module(codegen)
    full=set(result['results'])==set(codegen.FEATURES) and all(set(v)==set(codegen.FLAGS) for v in result['results'].values())
    enough=all(s['accepted_cycles']>=15 for v in result['results'].values() for s in v.values())
    result.update(sessions=sessions,cpus=sorted({s['cpu'] for s in sessions}),
        coverage='full' if full else 'requested subset',status='measured' if full and enough else 'inconclusive')
    args.output.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()
