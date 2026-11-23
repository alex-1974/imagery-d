"""Paired optional-target experiment; never changes the portable CPU floor.

Each executable must come from the same source with only its target flags
changed. Uses prepared kernel clocks, full output observation, an unchanged
Canny control and the same hygiene/whole-cycle bootstrap as issue #212.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from measurement_protocol import hygiene, summarize, select_cpu, cpu_list, raw_diagnostic
from canny_reference import build, validate

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ['gaussian32', 'gradient', 'median', 'ridge', 'gabor', 'hessian',
            'pathOpening', 'localNormalization']
FLAGS = {'portable': '', 'v3': '--mcpu=x86-64-v3', 'native': '--mcpu=native'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cpu', default='auto')
    parser.add_argument('--size', type=int, default=1024)
    parser.add_argument('--cycles', type=int, default=15)
    parser.add_argument('--max-cycles', type=int, default=90)
    parser.add_argument('--max-seconds', type=float, help='optional per-setting collection cap, checked only after complete cycles')
    parser.add_argument('--features', nargs='+', choices=FEATURES, default=FEATURES)
    parser.add_argument('--settings', nargs='+', choices=list(FLAGS), default=list(FLAGS))
    parser.add_argument('--binary-source', help='commit used for retained binaries; defaults to build manifest')
    parser.add_argument('--baseline-artifacts', type=Path, help='compare sources at identical targets instead of comparing ISA settings')
    args = parser.parse_args()
    if args.cycles < 15 or args.max_cycles < args.cycles:
        parser.error('at least 15 complete accepted cycles required')
    if args.max_seconds is not None and args.max_seconds<=0:parser.error('positive collection cap required')
    artifacts = args.artifacts.resolve()
    baselines = args.baseline_artifacts.resolve() if args.baseline_artifacts else artifacts
    args.output.mkdir(parents=True, exist_ok=True)
    reference, control_build = build(args.output/'control')
    primitive_cases=json.loads(subprocess.check_output([str(artifacts/'portable-oracle'),'--primitives'],text=True))
    control_validation=validate(reference,primitive_cases)
    control, control_edges=reference.prepare([(i*37%257)/256 for i in range(64*64)],64,64,.1,.2)
    cpu, selection = select_cpu(args.cpu)
    family = cpu_list(Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list').read_text())
    observers = os.sched_getaffinity(0) - family
    if observers:
        os.sched_setaffinity(0, {min(observers)})
    report = dict(schema=1, cpu=cpu, selection=selection, size=args.size,
        observer_affinity=sorted(os.sched_getaffinity(0)), host=platform.platform(),
        compiler=subprocess.check_output(['ldc-1.43.0', '--version'], text=True),
        source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        tracked_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True)),
        binary_source=args.binary_source or (artifacts/'source.txt').read_text().strip(),
        control_build=control_build,control_validation=control_validation,
        cpu_model=next(x.split(':',1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),
        contract='prepared Float32 input; strict worker except opt-in Gaussian32; Hessian three scales 1,2,4; frame copy/hash outside clock',
        hygiene=dict(max_load=6., max_frequency_change=.05, max_sibling_busy_fraction=.05),
        builds={}, results={})
    report['maximum_collection_seconds_per_setting']=args.max_seconds
    if args.baseline_artifacts:
        report['baseline_source']=(baselines/'source.txt').read_text().strip()
        report['baseline_builds']={}
    for target, flags in FLAGS.items():
        binary = artifacts / (target + '-bench')
        oracle = artifacts / (target + '-oracle')
        validation = artifacts / (target + '-numerical.txt')
        if not validation.exists() or not any(line.startswith('PASS:') for line in validation.read_text().splitlines()):
            raise ValueError('Independent oracle must pass for every target before timing')
        report['builds'][target] = dict(flags='DUB release; --gline-tables-only; '+flags,
            binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
            oracle_sha256=hashlib.sha256(oracle.read_bytes()).hexdigest(),
            numerical_sha256=hashlib.sha256(validation.read_bytes()).hexdigest(),
            remarks_sha256=hashlib.sha256((artifacts/(target+'-build.log')).read_bytes()).hexdigest())
        if args.baseline_artifacts:
            validation=baselines/(target+'-numerical.txt')
            if not any(line.startswith('PASS:') for line in validation.read_text().splitlines()):
                raise ValueError('Baseline numerical oracle must pass')
            report['baseline_builds'][target]=dict(flags=report['builds'][target]['flags'],
                binary_sha256=hashlib.sha256((baselines/(target+'-bench')).read_bytes()).hexdigest(),
                oracle_sha256=hashlib.sha256((baselines/(target+'-oracle')).read_bytes()).hexdigest(),
                numerical_sha256=hashlib.sha256(validation.read_bytes()).hexdigest())

    def measure(target, feature, directory):
        observer=os.sched_getaffinity(0)
        def unchanged_control():
            os.sched_setaffinity(0,{cpu})
            try:
                control()  # identical warm-cache state before both clocks
                start=time.perf_counter_ns();control();ns=time.perf_counter_ns()-start
                digest=hashlib.sha256(control_edges).hexdigest()
                return ns,digest
            finally:os.sched_setaffinity(0,observer)
        before_control,before_digest=unchanged_control()
        command = ['taskset', '-c', str(cpu), str(directory/(target+'-bench')),
                   str(args.size), '1', 'sample', 'scalar', feature]
        row = json.loads(subprocess.check_output(command, cwd=ROOT, text=True))
        after_control,after_digest=unchanged_control()
        if before_digest!=after_digest:raise ValueError('C control output changed')
        row['compiled_target_control']={key:row[key] for key in ['control_before_ns','control_after_ns','control_digest']}
        row.update(control_before_ns=before_control,control_after_ns=after_control,control_digest=after_digest,
            control_scope='same portable C shared object, pinned measured core, identical preheat')
        if row['gc_bytes'] != 0 or row.get('input_storage') != 'float32':
            raise ValueError('Prepared kernels must have Float32 input and zero measured GC bytes')
        row['target'] = target
        row['hygiene'] = hygiene(row)
        return row

    report['status']='collecting'
    (args.output/'codegen.json').write_text(json.dumps(report,indent=2)+'\n')
    for feature in args.features:
        report['results'][feature] = {}
        for target in args.settings:
            groups = []
            raw=args.output/(feature+'-'+target+'.raw.jsonl')
            raw.write_text('')
            collection_started=time.monotonic()
            for cycle in range(args.max_cycles):
                group = []
                baseline_target=target if args.baseline_artifacts else 'portable'
                cells=[('A',target,artifacts),('B',baseline_target,baselines),('B',baseline_target,baselines),('A',target,artifacts)]
                for position, (mode, setting, directory) in enumerate(cells):
                    row = measure(setting, feature, directory)
                    row.update(position=position, mode=mode, cycle=cycle)
                    group.append(row)
                # Different compiler targets may round floating operations
                # differently; independent per-target oracle is the numerical
                # admission. Exact fingerprints are still retained/reported.
                groups.append(group)
                with raw.open('a') as stream:stream.write(json.dumps(group)+'\n')
                if sum(all(r['hygiene']['accepted'] for r in g) for g in groups) >= args.cycles:
                    break
                if args.max_seconds is not None and time.monotonic()-collection_started>=args.max_seconds:
                    break
                time.sleep(.1)
            controls = {r['control_digest'] for g in groups for r in g}
            if len(controls) != 1:
                raise ValueError('Unchanged control produced different output')
            summary = summarize(groups, require_equal_outputs=bool(args.baseline_artifacts))
            summary['raw_diagnostic']=raw_diagnostic(groups,require_equal_outputs=bool(args.baseline_artifacts))
            summary['exact_output_identity'] = len({r['digest'] for g in groups for r in g}) == 1
            report['results'][feature][target] = summary
            (args.output/(feature+'-'+target+'.json')).write_text(json.dumps(groups,indent=2)+'\n')
            (args.output/'codegen.json').write_text(json.dumps(report,indent=2)+'\n')
            print(feature,target,json.dumps(summary),flush=True)
    enough=all(s['accepted_cycles']>=15 for v in report['results'].values() for s in v.values())
    report['coverage']='full' if set(report['results'])==set(FEATURES) and all(
        set(variants)==set(FLAGS) for variants in report['results'].values()) else 'requested subset'
    report['status'] = ('measured' if report['coverage']=='full' else 'subset_measured') if enough else 'inconclusive'
    (args.output/'codegen.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
