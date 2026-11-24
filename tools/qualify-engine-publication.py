"""Same-target before/after Engine cells; keep view-only and full-frame scopes separate."""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

from measurement_protocol import cpu_list, distribution, hygiene, raw_diagnostic, select_cpu, summarize

ROOT = Path(__file__).resolve().parents[1]
MODES = ['cold64', 'cold32', 'warm', 'cold64-view', 'cold32-view', 'warm-view']
FEATURES = ['gaussian', 'gradient', 'median', 'ridge', 'gabor']



def publication_status(report, policy, requested):
    """An incremental/subset receipt cannot admit the complete policy."""
    collected=report.get('results',{})
    expected={f'{f}/{m}' for f in policy['operators'] for m in policy['eligible_modes']}
    minimum=max(report.get('minimum_cycles',15),policy['minimum_cycles'])
    report['coverage']=dict(missing_requested=sorted(set(requested)-collected.keys()),
        missing_policy=sorted(expected-collected.keys()),
        insufficient_requested=sorted(k for k in requested
            if collected.get(k,{}).get('accepted_cycles',0)<minimum))
    incomplete=report['coverage']['missing_requested'] or report['coverage']['insufficient_requested']
    if not report.get('numerical_preflight'):return 'pending'
    if not report.get('instrumented'):
        return 'pending' if incomplete else 'measured_without_phase_admission'
    statuses=[g['status'] for g in report.get('gates',[])]
    if 'fail' in statuses:return 'fail'
    if incomplete or report['coverage']['missing_policy'] or len(statuses)!=len(expected):return 'pending'
    return 'pass' if all(s=='pass' for s in statuses) else 'pending'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--baseline', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--features', nargs='+', choices=FEATURES, default=FEATURES)
    p.add_argument('--modes', nargs='+', choices=MODES, default=MODES)
    p.add_argument('--cpu', default='auto')
    p.add_argument('--size', type=int, default=1024)
    p.add_argument('--cycles', type=int, default=15)
    p.add_argument('--max-cycles', type=int, default=90)
    p.add_argument('--max-seconds', type=float, default=300)
    p.add_argument('--oracle', type=Path, required=True)
    p.add_argument('--compiler',default='ldc-1.43.0')
    p.add_argument('--build-flags',default='DUB release; --gline-tables-only; portable')
    p.add_argument('--instrumented',action='store_true',help='binaries built with ImageryProfile; phase admission is separate from ordinary release time')
    p.add_argument('--diagnostic', action='store_true')
    p.add_argument('--targets',type=Path,default=ROOT/'docs/benchmarks/performance-targets.json')
    args = p.parse_args()
    if args.cycles < 15 or args.max_cycles < args.cycles or args.max_seconds <= 0:
        p.error('>=15 accepted cycles and a positive declared collection cap required')
    if len(set(args.features))!=len(args.features) or len(set(args.modes))!=len(args.modes):
        p.error('duplicate features or modes would overwrite retained raw cells')
    policy=json.loads(args.targets.read_text())['engine_publication']
    if args.size!=policy['size']:p.error('view-only admission requires the fixed policy size')
    args.output.mkdir(parents=True, exist_ok=True)
    numerical = subprocess.check_output([sys.executable, str(ROOT/'tools/verify-feature-program.py'),
        str(args.oracle.resolve())], cwd=ROOT, text=True)
    (args.output/'numerical.txt').write_text(numerical)
    cpu, selection = select_cpu(args.cpu)
    family = cpu_list(Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list').read_text())
    observers = os.sched_getaffinity(0)-family
    if observers:
        os.sched_setaffinity(0, {min(observers)})
    binaries = {'after': args.binary.resolve(), 'before': args.baseline.resolve()}
    report = dict(instrumented=args.instrumented, schema=1,
        compiler=subprocess.check_output([args.compiler,'--version'],text=True),build_flags=args.build_flags,
        oracle_sha256=hashlib.sha256(args.oracle.read_bytes()).hexdigest(), numerical_preflight=True, size=args.size, cpu=cpu, selection=selection,
        contract='strict-float64/final-float32; complete-frame and view-only are distinct scopes',
        minimum_cycles=args.cycles, maximum_seconds_per_case=args.max_seconds,
        hygiene=dict(load_limit=6., frequency_limit=.05, sibling_busy_fraction=.05),
        observer_affinity=sorted(os.sched_getaffinity(0)),
        source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        binaries={k:dict(path=str(v),sha256=hashlib.sha256(v.read_bytes()).hexdigest(),
            source=(v.parent/'source.txt').read_text().strip()) for k,v in binaries.items()},
        results={}, gates=[], status='pending')
    spec=importlib.util.spec_from_file_location('targets',ROOT/'tools/check-performance-targets.py')
    checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)

    requested={f'{f}/{m}' for f in args.features for m in args.modes}

    def save():
        report['status']=publication_status(report,policy,requested)
        (args.output/'engine-publication.json').write_text(json.dumps(report,indent=2)+'\n')

    save()
    for feature in args.features:
        for mode in args.modes:
            groups=[]
            began=time.monotonic()
            path=args.output/f'{feature}-{mode}.raw.jsonl'
            with path.open('w') as stream:
                for cycle in range(args.max_cycles):
                    rows=[]
                    for position,kind in enumerate(['after','before','before','after']):
                        command=['taskset','-c',str(cpu),str(binaries[kind]),str(args.size),'1',
                            'engine-sample','scalar',feature,mode]
                        row=json.loads(subprocess.check_output(command,cwd=ROOT,text=True))
                        row.update(cycle=cycle,position=position,build=kind)
                        row['hygiene']=hygiene(row)
                        if row['computed_tiles']<=0 or (mode.startswith('warm') and row['gc_bytes']):
                            raise ValueError('Actual computed work and zero warm GC bytes required')
                        rows.append(row)
                    if len({r['digest'] for r in rows})!=1:
                        raise ValueError('Before/after complete output fingerprints differ')
                    groups.append(rows)
                    stream.write(json.dumps(rows)+'\n');stream.flush()
                    summary=summarize(groups)
                    if summary['accepted_cycles']>=args.cycles or time.monotonic()-began>=args.max_seconds:
                        break
                    time.sleep(.1)
            summary['raw_diagnostic']=raw_diagnostic(groups)
            summary['exact_output_identity']=True
            accepted=[g for g in groups if all(r['hygiene']['accepted'] for r in g)]
            phases={}
            for phase in ['source','prepare','kernel','cache','sink','overhead']:
                def value(r):
                    fields=['source','prepare','cache','sink'] if phase=='overhead' else [phase]
                    return sum(r['phases_ns'][k] for k in fields)/args.size**2
                samples=[math.sqrt(value(g[0])*value(g[3])) for g in accepted]
                if samples and all(x>0 for x in samples):
                    phases[phase]=distribution(samples)
            summary['after_phases']=phases
            summary['borrowed_plane_tiles']=sum(r.get('borrowed_plane_tiles',0) for g in groups for r in [g[0],g[3]])
            report['results'][f'{feature}/{mode}']=summary
            # This is an explicit new view-only envelope, never a replacement
            # for the old complete-frame Engine/worker ratio admissions.
            if args.instrumented and mode in policy['eligible_modes']:
                report['gates'].append(checker.interval_gate(phases.get('overhead',{}),policy['maximum_overhead_ns_per_pixel'],
                    f'{feature}/{mode}: view-only overhead',False))
            save()
            print(feature,mode,summary['accepted_cycles'],summary.get('ratio'),flush=True)
    if not args.diagnostic:
        raise SystemExit({'pass':0,'pending':2,'fail':1,'measured_without_phase_admission':0}[report['status']])


if __name__=='__main__':
    main()
